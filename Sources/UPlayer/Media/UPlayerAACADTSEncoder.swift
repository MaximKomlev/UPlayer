//
//  File.swift
//  UPlayer
//
//  Created by Max Komleu on 4/29/26.
//

import Foundation
import AVFoundation
import AudioToolbox

public final class UPlayerAACADTSEncoder {

    public init() {}

    public func encodePCMToAACADTS(pcm: [Int16],
                                   sampleRate: Double,
                                   channels: UInt32,
                                   bitrate: UInt32 = 64_000) throws -> Data {

        guard !pcm.isEmpty else {
            return Data()
        }

        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: true
        ) else {
            throw UPlayerErrorsList.aacEncodongFailed1
        }

        var outputASBD = AudioStreamBasicDescription(mSampleRate: sampleRate,
                                                     mFormatID: kAudioFormatMPEG4AAC,
                                                     mFormatFlags: UInt32(MPEG4ObjectID.AAC_LC.rawValue),
                                                     mBytesPerPacket: 0,
                                                     mFramesPerPacket: 1024,
                                                     mBytesPerFrame: 0,
                                                     mChannelsPerFrame: channels,
                                                     mBitsPerChannel: 0,
                                                     mReserved: 0)

        guard let outputFormat = AVAudioFormat(streamDescription: &outputASBD) else {
            throw UPlayerErrorsList.aacEncodongFailed2
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw UPlayerErrorsList.aacEncodongFailed3
        }

        converter.bitRate = Int(bitrate)

        let frameCapacity = AVAudioFrameCount(pcm.count / Int(channels))

        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat,
                                                 frameCapacity: frameCapacity) else {
            throw UPlayerErrorsList.aacEncodongFailed4
        }

        inputBuffer.frameLength = frameCapacity

        try pcm.withUnsafeBytes { rawBuffer in
            guard let source = rawBuffer.baseAddress else { return }

            guard let channelData = inputBuffer.int16ChannelData else {
                throw UPlayerErrorsList.aacEncodongFailed5
            }

            let byteCount = pcm.count * MemoryLayout<Int16>.size
            let dst = channelData[0]

            memcpy(dst, source, byteCount)
        }

        var didProvideInput = false
        var output = Data()

        while true {
            guard let compressedBuffer = AVAudioCompressedBuffer(format: outputFormat,
                                                                 packetCapacity: 1,
                                                                 maximumPacketSize: converter.maximumOutputPacketSize) as AVAudioCompressedBuffer? else {
                throw UPlayerErrorsList.aacEncodongFailed6
            }

            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                if didProvideInput {
                    outStatus.pointee = .endOfStream
                    return nil
                }

                didProvideInput = true
                outStatus.pointee = .haveData
                return inputBuffer
            }

            var error: NSError?
            let status = converter.convert(
                to: compressedBuffer,
                error: &error,
                withInputFrom: inputBlock
            )

            if let error {
                throw error
            }

            switch status {
            case .haveData:
                let dataSize = Int(compressedBuffer.audioBufferList.pointee.mBuffers.mDataByteSize)

                guard dataSize > 0,
                      let rawData = compressedBuffer.audioBufferList.pointee.mBuffers.mData else {
                    continue
                }

                let aacPayload = Data(bytes: rawData, count: dataSize)

                let header = createAACHeader(format: outputFormat.streamDescription.pointee,
                                             headerLength: 7,
                                             bodyLength: UInt32(dataSize))

                output.append(header)
                output.append(aacPayload)

            case .inputRanDry:
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
}


func createAACHeader(format: AudioStreamBasicDescription,
                     headerLength: UInt32,
                     bodyLength: UInt32) -> Data {
    var header = Data()

    let profile = format.mFormatFlags
    let freqIdx = UInt32(freqIdxForADTSHeader(sampleRate: Int(format.mSampleRate)))
    let chanCfg = format.mChannelsPerFrame
    let fullLength = headerLength + bodyLength

    var adtsHeader = [UInt8](repeating: 0, count: Int(headerLength))

    adtsHeader[0] = 0xFF
    adtsHeader[1] = 0xF9

    adtsHeader[2] = UInt8(((profile - 1) & 0x3) << 6)
    adtsHeader[2] |= UInt8((freqIdx & 0xF) << 2)
    adtsHeader[2] |= UInt8((chanCfg & 0x4) >> 2)

    adtsHeader[3] = UInt8((chanCfg & 0x3) << 6)
    adtsHeader[3] |= UInt8((fullLength & 0x1800) >> 11)

    adtsHeader[4] = UInt8((fullLength & 0x07F8) >> 3)

    adtsHeader[5] = UInt8((fullLength & 0x7) << 5)
    adtsHeader[5] |= 0x1F

    adtsHeader[6] = 0xFC

    header.append(adtsHeader, count: Int(headerLength))
    return header
}

func freqIdxForADTSHeader(sampleRate: Int) -> Int {
    switch sampleRate {
    case 7350..<8000: return 12
    case 8000..<11025: return 11
    case 11025..<12000: return 10
    case 12000..<16000: return 9
    case 16000..<22050: return 8
    case 22050..<24000: return 7
    case 24000..<32000: return 6
    case 32000..<44100: return 5
    case 44100..<48000: return 4
    case 48000..<64000: return 3
    case 64000..<88200: return 2
    case 88200..<96000: return 1
    case 96000...: return 0
    default: return 4
    }
}
