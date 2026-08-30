//
//  UPlayerAACEncoder.swift
//  UPlayer
//
//  Created by Max Komleu on 8/29/26.
//

import Foundation
import AVFoundation
import AudioToolbox

public struct UPlayerAACPacket {
    public let data: Data
    public let duration: UInt32
}

public struct UPlayerAACEncodedAudio {
    
    public let packets: [UPlayerAACPacket]
    
    public let sampleRate: UInt32
    public let channels: UInt32
    
    public let framesPerPacket: UInt32
    
    public var duration: UInt64 {
        packets.reduce(UInt64(0)) {
            $0 + UInt64($1.duration)
        }
    }
}

public final class UPlayerAACEncoder {

    public init() {}

    public func encodePCMToAAC(pcm: [Int16],
                               sourceSampleRate: Double,
                               outputSampleRate: Double,
                               channels: UInt32,
                               bitrate: UInt32 = 32_000) throws -> UPlayerAACEncodedAudio {

        guard !pcm.isEmpty,
              channels > 0 else {

            return UPlayerAACEncodedAudio(packets: [],
                                          sampleRate: UInt32(outputSampleRate),
                                          channels: channels,
                                          framesPerPacket: 1024)
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

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
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

        log(
            """
            [aac encoder] converter
            inputFramesPerPacket=\(inputFormat.streamDescription.pointee.mFramesPerPacket)
            outputFramesPerPacket=\(outputFormat.streamDescription.pointee.mFramesPerPacket)
            primeLeadingFrames=\(converter.primeInfo.leadingFrames)
            primeTrailingFrames=\(converter.primeInfo.trailingFrames)
            """,
            loggingLevel: .debug
        )
        
        converter.bitRate = Int(bitrate)

        let totalFrames = pcm.count / Int(channels)
        var sourceFrameOffset = 0
        var packets: [UPlayerAACPacket] = []
        let outputPacketCapacity: AVAudioPacketCount = 32
        var consecutiveInputRanDryCount = 0

        let reportedFramesPerPacket =
            outputFormat
                .streamDescription
                .pointee
                .mFramesPerPacket

        /*
         AAC-LC uses 1024 PCM frames per AAC access unit.

         AVAudioFormat(settings:) may report
         mFramesPerPacket == 0 for the compressed format,
         so do not propagate zero into trun.sample_duration.
        */
        let outputFramesPerPacket: UInt32 = reportedFramesPerPacket > 0 ? reportedFramesPerPacket : 1024

        log("""
            [aac encoder] output format
            reportedFramesPerPacket=\(reportedFramesPerPacket)
            effectiveFramesPerPacket=\(outputFramesPerPacket)
            sampleRate=\(outputSampleRate)
            """,
            loggingLevel: .debug)
        
        while true {
            let maximumPacketSize = maximumAACPacketSize(converter: converter,
                                                         bitrate: bitrate,
                                                         sampleRate: outputSampleRate)

            let compressedBuffer = AVAudioCompressedBuffer(format: outputFormat,
                                                           packetCapacity: outputPacketCapacity,
                                                           maximumPacketSize: maximumPacketSize)

            let inputBlock: AVAudioConverterInputBlock = { requestedPacketCount, outStatus in
                    guard sourceFrameOffset < totalFrames else {
                        outStatus.pointee = .endOfStream
                        return nil
                    }

                    let inputFramesPerPacket = max(1, Int(inputFormat.streamDescription.pointee.mFramesPerPacket))
                    let requestedFrames = max(1, Int(requestedPacketCount) * inputFramesPerPacket)
                    let remainingFrames = totalFrames - sourceFrameOffset
                    let frameCount = min(requestedFrames, remainingFrames)

                    guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat,
                                                        frameCapacity: AVAudioFrameCount(frameCount)) else {
                        outStatus.pointee = .noDataNow
                        return nil
                    }

                    buffer.frameLength = AVAudioFrameCount(frameCount)

                    guard let destination = buffer.int16ChannelData?[0] else {
                        outStatus.pointee = .noDataNow
                        return nil
                    }

                    let channelCount = Int(channels)
                    let sourceOffset = sourceFrameOffset * channelCount
                    let sampleCount = frameCount * channelCount

                    pcm.withUnsafeBufferPointer { pointer in
                        guard let source = pointer.baseAddress else {
                            return
                        }

                        destination.update(from: source.advanced(by: sourceOffset), count: sampleCount)
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
                try appendPackets(from: compressedBuffer,
                                  defaultFramesPerPacket: outputFramesPerPacket,
                                  to: &packets)
            }

            switch status {
            case .haveData:
                consecutiveInputRanDryCount = 0
                continue
            case .inputRanDry:
                consecutiveInputRanDryCount += 1
                guard consecutiveInputRanDryCount < 16 else {
                    throw UPlayerErrorsList.aacEncodongFailed7
                }
                continue
            case .endOfStream:
                return UPlayerAACEncodedAudio(packets: packets,
                                              sampleRate: UInt32(outputSampleRate),
                                              channels: channels,
                                              framesPerPacket: outputFramesPerPacket)
            case .error:
                throw UPlayerErrorsList.aacEncodongFailed7
            @unknown default:
                throw UPlayerErrorsList.aacEncodongFailed7
            }
        }
    }
}

private extension UPlayerAACEncoder {
    private func appendPackets(from buffer: AVAudioCompressedBuffer, defaultFramesPerPacket: UInt32, to packets: inout [UPlayerAACPacket]) throws {

        let packetCount = Int(buffer.packetCount)
        guard packetCount > 0 else {
            return
        }

        let byteLength = Int(buffer.byteLength)
        guard byteLength > 0 else {
            return
        }

        let baseAddress = buffer.data
        guard let descriptions = buffer.packetDescriptions else {
            guard packetCount == 1 else {
                throw UPlayerErrorsList.aacEncodongFailed7
            }

            packets.append(UPlayerAACPacket(data: Data(bytes: baseAddress,
                                                       count: byteLength), duration: defaultFramesPerPacket))

            return
        }

        for index in 0..<packetCount {

            let description = descriptions[index]
            let offset = Int(description.mStartOffset)
            let size = Int(description.mDataByteSize)

            guard offset >= 0,
                  size > 0,
                  offset + size <= byteLength else {
                throw UPlayerErrorsList.aacEncodongFailed7
            }

            let packetData = Data(bytes: baseAddress.advanced(by: offset), count: size)

            let duration = description.mVariableFramesInPacket > 0 ? description.mVariableFramesInPacket : defaultFramesPerPacket

            packets.append(UPlayerAACPacket(data: packetData,
                                            duration: duration))
            
            log("""
                [aac encoder] packet \(index)
                bytes=\(size)
                variableFrames=\(description.mVariableFramesInPacket)
                startOffset=\(description.mStartOffset)
                """,
                loggingLevel: .debug)
        }
    }

    func maximumAACPacketSize(converter: AVAudioConverter, bitrate: UInt32, sampleRate: Double) -> Int {
        let reported = converter.maximumOutputPacketSize
        if reported > 0 {
            return reported
        }

        let average = Double(bitrate) / 8.0 * 1024.0 / sampleRate
        return max(2048, Int(ceil(average * 4.0)))
    }
}
