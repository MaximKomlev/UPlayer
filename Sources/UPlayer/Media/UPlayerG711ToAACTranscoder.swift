//
//  UPlayerAudioTranscoder.swift
//  UPlayer
//
//  Created by Max Komleu on 4/29/26.
//

import Foundation
import AVFoundation
import AudioToolbox

public final class UPlayerG711ToAACTranscoder: UPlayerAudioTranscoderProtocol {

    public enum G711Codec {
        case alaw
        case ulaw
    }

    private let sampleRate: Double
    private let channels: UInt32
    private let bitrate: UInt32
    
    private let aacEncoder = UPlayerAACADTSEncoder()

    public init(sampleRate: Double = 8000,
                channels: UInt32 = 1,
                bitrate: UInt32 = 64000) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitrate = bitrate
    }

    public func transcodeAudioSegment(data: Data,
                                      originalCodec: String?,
                                      sourceURL: URL) async throws -> Data {

        let codec = try detectG711Codec(originalCodec: originalCodec)

        let pcm = decodeG711ToPCM(data: data,
                                  codec: codec)

        return try encodePCMToAACADTS(pcm: pcm,
                                      sampleRate: sampleRate,
                                      channels: channels,
                                      bitrate: bitrate)
    }

    private func detectG711Codec(originalCodec: String?) throws -> G711Codec {
        let codec = originalCodec?.lowercased() ?? ""

        if codec.contains("alaw") || codec.contains("pcma") || codec.contains("g711a") {
            return .alaw
        }

        if codec.contains("ulaw") || codec.contains("mulaw") || codec.contains("pcmu") || codec.contains("g711u") {
            return .ulaw
        }

        throw UPlayerErrorsList.aacEncodongFailed8
    }
}

private extension UPlayerG711ToAACTranscoder {

    func decodeG711ToPCM(data: Data,
                         codec: G711Codec) -> [Int16] {
        data.map { byte in
            switch codec {
            case .alaw:
                return decodeALaw(byte)
            case .ulaw:
                return decodeULaw(byte)
            }
        }
    }

    func decodeULaw(_ uValue: UInt8) -> Int16 {
        let u = ~uValue
        let sign = u & 0x80
        let exponent = (u >> 4) & 0x07
        let mantissa = u & 0x0F

        var sample = Int32(mantissa) << 3
        sample += 0x84
        sample <<= Int32(exponent)
        sample -= 0x84

        return sign != 0 ? Int16(-sample) : Int16(sample)
    }

    func decodeALaw(_ aValue: UInt8) -> Int16 {
        let a = aValue ^ 0x55
        let sign = a & 0x80
        let exponent = (a & 0x70) >> 4
        let mantissa = a & 0x0F

        var sample: Int32

        if exponent == 0 {
            sample = Int32(mantissa) << 4
            sample += 8
        } else {
            sample = Int32(mantissa) << 4
            sample += 0x108
            sample <<= Int32(exponent - 1)
        }

        return sign != 0 ? Int16(sample) : Int16(-sample)
    }
}

private extension UPlayerG711ToAACTranscoder {

    func encodePCMToAACADTS(pcm: [Int16],
                            sampleRate: Double,
                            channels: UInt32,
                            bitrate: UInt32) throws -> Data {
        return try aacEncoder.encodePCMToAACADTS(pcm: pcm,
                                                 sampleRate: sampleRate,
                                                 channels: channels,
                                                 bitrate: bitrate)
    }
}
