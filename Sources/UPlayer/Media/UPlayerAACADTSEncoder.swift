//
//  File.swift
//  UPlayer
//
//  Created by Max Komleu on 4/29/26.
//

import AVFoundation
import AudioToolbox
import Foundation

public final class UPlayerAACADTSEncoder {

    public init() {}

    public func encodePCMToAACADTS(pcm: [Int16],
                                   sourceSampleRate: Double,
                                   outputSampleRate: Double,
                                   channels: UInt32,
                                   bitrate: UInt32 = 64_000) throws -> Data {
    
        guard !pcm.isEmpty,
              channels > 0 else {
            return Data()
        }

        guard pcm.count % Int(channels) == 0 else {
            throw UPlayerErrorsList.aacEncodongFailed1
        }

        guard let inputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                              sampleRate: sourceSampleRate,
                                              channels: channels,
                                              interleaved: true) else {
            throw UPlayerErrorsList.aacEncodongFailed1
        }

        let outputSettings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                           AVSampleRateKey: outputSampleRate,
                                     AVNumberOfChannelsKey: Int(channels),
                                       AVEncoderBitRateKey: Int(bitrate)
        ]

        guard let outputFormat = AVAudioFormat(settings: outputSettings) else {
            throw UPlayerErrorsList.aacEncodongFailed2
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw UPlayerErrorsList.aacEncodongFailed3
        }

        converter.bitRate = Int(bitrate)
        
        let totalFrames = pcm.count / Int(channels)

        var sourceFrameOffset = 0
        var output = Data()

        /*
         Let the converter emit multiple AAC packets per pass.

         We don't need capacity for the entire 8-second segment;
         repeated convert() calls drain everything.
        */
        let outputPacketCapacity: AVAudioPacketCount = 32

        while true {
            let maximumPacketSize = maximumAACPacketSize(converter: converter,
                                                         bitrate: bitrate,
                                                         sampleRate: outputSampleRate)

            let compressedBuffer = AVAudioCompressedBuffer(format: outputFormat,
                                                           packetCapacity: outputPacketCapacity,
                                                           maximumPacketSize: maximumPacketSize)
            
            let inputBlock:
                AVAudioConverterInputBlock = { requestedPacketCount, outStatus in

                    guard sourceFrameOffset < totalFrames else {
                        outStatus.pointee = .endOfStream
                        return nil
                    }

                    let requestedFrames = max(1, Int(requestedPacketCount))
                    let remainingFrames = totalFrames - sourceFrameOffset
                    let frameCount = min(requestedFrames, remainingFrames)

                    guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
                        outStatus.pointee = .noDataNow
                        return nil
                    }

                    buffer.frameLength = AVAudioFrameCount(frameCount)

                    guard let destination = buffer.int16ChannelData?[0] else {
                        outStatus.pointee = .noDataNow
                        return nil
                    }

                    let channelsInt = Int(channels)

                    let sourceSampleOffset = sourceFrameOffset * channelsInt

                    let sampleCount = frameCount * channelsInt

                    pcm.withUnsafeBufferPointer { pointer in

                        guard let source = pointer.baseAddress else {
                            return
                        }

                        destination.update(from:source.advanced(by:sourceSampleOffset), count: sampleCount)
                    }

                    sourceFrameOffset += frameCount
                    outStatus.pointee = .haveData

                    return buffer
                }

            var conversionError: NSError?

            let status = converter.convert(to: compressedBuffer, error: &conversionError, withInputFrom: inputBlock)

            if let conversionError {
                throw conversionError
            }

            if compressedBuffer.packetCount > 0 {
                try appendAACPackets(from: compressedBuffer, format: outputFormat.streamDescription.pointee, to: &output)
            }

            switch status {

            case .haveData:
                continue

            case .inputRanDry:
                /*
                 More input may still exist.
                 Continue and let the converter request it.
                */
                if sourceFrameOffset < totalFrames {
                    continue
                }

                /*
                 Input is exhausted but converter may still need
                 another call to flush delayed AAC output.
                */
                continue

            case .endOfStream:
                return output

            case .error:
                throw UPlayerErrorsList.aacEncodongFailed7

            @unknown default:
                return output
            }
        }
    }
    
    func maximumAACPacketSize(converter: AVAudioConverter,
                              bitrate: UInt32,
                              sampleRate: Double) -> Int {

        let reported = converter.maximumOutputPacketSize

        if reported > 0 {
            return reported
        }

        /*
         AAC LC = 1024 PCM frames per packet.

         Estimate encoded bytes per packet:
             bitrate / 8 * 1024 / sampleRate

         Then multiply generously for VBR/header/encoder variation.
        */

        let averagePacketBytes = Double(bitrate) / 8.0 * 1024.0 / sampleRate
        let safeEstimate = Int(ceil(averagePacketBytes * 4.0))

        return max(2048, safeEstimate)
    }
}

private extension UPlayerAACADTSEncoder {

    func appendAACPackets(from buffer: AVAudioCompressedBuffer,
                          format: AudioStreamBasicDescription,
                          to output: inout Data) throws {

        let packetCount = Int(buffer.packetCount)
        guard packetCount > 0 else {
            return
        }

        let totalByteLength = Int(buffer.byteLength)
        guard totalByteLength > 0 else {
            return
        }

        let baseAddress = buffer.data

        if let descriptions = buffer.packetDescriptions {

            for index in 0 ..< packetCount {
                let description = descriptions[index]
                let packetOffset = Int(description.mStartOffset)
                let packetSize = Int(description.mDataByteSize)

                guard packetOffset >= 0,
                      packetSize > 0,
                      packetOffset + packetSize <= totalByteLength else {
                    throw UPlayerErrorsList.aacEncodongFailed7
                }

                appendADTSPacket(bytes: baseAddress.advanced(by: packetOffset), size: packetSize, format: format, output: &output)
            }

            return
        }

        /*
         AAC normally provides packetDescriptions, but handle a
         fixed-size/single-packet buffer defensively.
        */

        if packetCount == 1 {
            appendADTSPacket(bytes: baseAddress,
                             size: totalByteLength,
                             format: format,
                             output: &output)

            return
        }

        let bytesPerPacket = Int(format.mBytesPerPacket)

        guard bytesPerPacket > 0,
              bytesPerPacket * packetCount <= totalByteLength else {

            throw UPlayerErrorsList.aacEncodongFailed7
        }

        for index in 0 ..< packetCount {
            appendADTSPacket(bytes: baseAddress.advanced(by: index * bytesPerPacket), size: bytesPerPacket, format: format, output: &output)
        }
    }

    func appendADTSPacket(bytes: UnsafeRawPointer,
                          size: Int,
                          format: AudioStreamBasicDescription,
                          output: inout Data) {

        let header = createAACHeader(format: format,
                                     headerLength: 7,
                                     bodyLength: UInt32(size))

        output.append(header)
        output.append(bytes.assumingMemoryBound(to: UInt8.self), count: size)
    }
}

func createAACHeader(format: AudioStreamBasicDescription,
                     headerLength: UInt32,
                     bodyLength: UInt32) -> Data {

    let adtsProfile: UInt32 = 1 // AAC-LC

    let freqIdx = UInt32(freqIdxForADTSHeader(sampleRate: Int(format.mSampleRate)))

    let chanCfg = format.mChannelsPerFrame
    let fullLength = headerLength + bodyLength

    var adtsHeader = [UInt8](repeating: 0, count: Int(headerLength))

    adtsHeader[0] = 0xFF
    // MPEG-4, Layer 0, no CRC
    adtsHeader[1] = 0xF1
    // profile + sampling frequency index + first channel bit
    adtsHeader[2] = UInt8((adtsProfile & 0x3) << 6)
    adtsHeader[2] |= UInt8((freqIdx & 0xF) << 2)
    adtsHeader[2] |= UInt8((chanCfg & 0x4) >> 2)
    // remaining channel bits + frame length bits
    adtsHeader[3] = UInt8((chanCfg & 0x3) << 6)
    adtsHeader[3] |= UInt8((fullLength & 0x1800) >> 11)
    adtsHeader[4] = UInt8((fullLength & 0x07F8) >> 3)
    adtsHeader[5] = UInt8((fullLength & 0x7) << 5)
    // VBR buffer fullness
    adtsHeader[5] |= 0x1F
    adtsHeader[6] = 0xFC

    return Data(adtsHeader)
}

func freqIdxForADTSHeader(sampleRate: Int) -> Int {

    switch sampleRate {
    case 7350 ..< 8000:
        return 12
    case 8000 ..< 11025:
        return 11
    case 11025 ..< 12000:
        return 10
    case 12000 ..< 16000:
        return 9
    case 16000 ..< 22050:
        return 8
    case 22050 ..< 24000:
        return 7
    case 24000 ..< 32000:
        return 6
    case 32000 ..< 44100:
        return 5
    case 44100 ..< 48000:
        return 4
    case 48000 ..< 64000:
        return 3
    case 64000 ..< 88200:
        return 2
    case 88200 ..< 96000:
        return 1
    case 96000...:
        return 0
    default:
        return 4
    }
}

internal func dumpAACData(_ data: Data) {
    print("AAC size: \(data.count) bytes")

    let bytes = [UInt8](data)

    // First 64 bytes
    let count = min(64, bytes.count)

    let hex = bytes.prefix(count)
        .map { String(format: "%02X", $0) }
        .joined(separator: " ")

    print("AAC first \(count) bytes:")
    print(hex)
}

internal func validateADTS(_ data: Data, logScope: String) -> Bool {
    let bytes = [UInt8](data)

    var offset = 0
    var frameNumber = 0

    while offset + 7 <= bytes.count {
        // 12-bit ADTS syncword = 0xFFF
        guard bytes[offset] == 0xFF,
              (bytes[offset + 1] & 0xF0) == 0xF0 else {
            log("\(logScope) Invalid ADTS sync at offset \(offset)", loggingLevel: .error)
            return false
        }

        let protectionAbsent = bytes[offset + 1] & 0x01

        let profile =
            (bytes[offset + 2] >> 6) & 0x03

        let frequencyIndex =
            (bytes[offset + 2] >> 2) & 0x0F

        let channelConfig =
            ((UInt16(bytes[offset + 2] & 0x01) << 2) |
             UInt16(bytes[offset + 3] >> 6))

        let frameLength =
            (Int(bytes[offset + 3] & 0x03) << 11) |
            (Int(bytes[offset + 4]) << 3) |
            (Int(bytes[offset + 5] >> 5))

        let headerLength = protectionAbsent == 1 ? 7 : 9

        guard frameLength >= headerLength else {
            log("\(logScope) Invalid frame length \(frameLength)", loggingLevel: .error)
            return false
        }

        guard offset + frameLength <= bytes.count else {
            log("\(logScope) Truncated ADTS frame \(frameNumber) offset: \(offset) frameLength: \(frameLength) dataSize: \(bytes.count)", loggingLevel: .error)
            return false
        }

        offset += frameLength
        frameNumber += 1
    }

    guard offset == bytes.count else {
        log("\(logScope) \(bytes.count - offset) trailing bytes", loggingLevel: .error)
        return false
    }

    return true
}
