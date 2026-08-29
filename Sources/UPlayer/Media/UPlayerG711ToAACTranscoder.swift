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

    private let channels: UInt32
    private let bitrate: UInt32

    private let sourceSampleRate: Double
    private let outputSampleRate: Double

    private let extractor = UPlayerFragmentedMP4AudioExtractor()

    private let aacEncoder = UPlayerAACADTSEncoder()

    public init(sourceSampleRate: Double = 8000,
                outputSampleRate: Double = 16000,
                channels: UInt32 = 1,
                bitrate: UInt32 = 32_000) {
        self.sourceSampleRate = sourceSampleRate
        self.outputSampleRate = outputSampleRate
        self.channels = channels
        self.bitrate = bitrate
    }
    
    public func transcodeAudioSegment(data: Data,
                                      initializationData: Data?,
                                      originalCodec: String?,
                                      sourceURL: URL) async throws -> UPlayerTranscodedAudioSegment {

        let codec = try detectG711Codec(originalCodec: originalCodec)

        let extracted = try extractor.extractSamples(initializationData: initializationData,
                                                     fragmentData: data)

        guard !extracted.samples.isEmpty else {
            throw UPlayerErrorsList.aacEncodongFailed8
        }

        let totalBytes = extracted.samples.reduce(0) {
            $0 + $1.count
        }

        var pcm: [Int16] = []
        pcm.reserveCapacity(totalBytes)

        for sample in extracted.samples {

            pcm.append(contentsOf: decodeG711ToPCM(data: sample, codec: codec))
        }

        guard !pcm.isEmpty else {
            throw UPlayerErrorsList.aacEncodongFailed8
        }

        let aacData = try aacEncoder.encodePCMToAACADTS(pcm: pcm,
                                                        sourceSampleRate: sourceSampleRate,
                                                        outputSampleRate: outputSampleRate,
                                                        channels: channels,
                                                        bitrate: bitrate)

        guard !aacData.isEmpty else {
            throw UPlayerErrorsList.aacEncodongFailed7
        }

        return UPlayerTranscodedAudioSegment(data: aacData,
                                             contentType: "audio/aac")
    }
}

private extension UPlayerG711ToAACTranscoder {

    func detectG711Codec(originalCodec: String?) throws -> G711Codec {

        let codec = originalCodec?.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""

        if codec.contains("alaw") ||
            codec.contains("pcma") ||
            codec.contains("g711a") ||
            codec.contains("g.711a") {

            return .alaw
        }

        if codec.contains("ulaw") ||
            codec.contains("mulaw") ||
            codec.contains("mu-law") ||
            codec.contains("pcmu") ||
            codec.contains("g711u") ||
            codec.contains("g.711u") {

            return .ulaw
        }

        throw UPlayerErrorsList.aacEncodongFailed8
    }
}

private extension UPlayerG711ToAACTranscoder {

    func decodeG711ToPCM(data: Data, codec: G711Codec) -> [Int16] {

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

        return sign != 0
            ? Int16(-sample)
            : Int16(sample)
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

        return sign != 0
            ? Int16(sample)
            : Int16(-sample)
    }
}
