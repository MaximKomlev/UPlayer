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

    private let aacEncoder = UPlayerAACEncoder()

    private let muxer = UPlayerAACFragmentedMP4Muxer()

    public init(sourceSampleRate: Double = 8_000,
                outputSampleRate: Double = 16_000,
                channels: UInt32 = 1,
                bitrate: UInt32 = 32_000) {

        self.sourceSampleRate = sourceSampleRate
        self.outputSampleRate = outputSampleRate
        self.channels = channels
        self.bitrate = bitrate
    }

    public func makeInitializationSegment(originalCodec: String?) async throws -> UPlayerTranscodedAudioSegment? {

        _ = try detectG711Codec(originalCodec:originalCodec)

        let data = try muxer.makeInitializationSegment(sampleRate: UInt32(outputSampleRate),
                                                       channels: channels,
                                                       bitrate: bitrate)

        return UPlayerTranscodedAudioSegment(data: data,
                                             contentType: "audio/mp4",
                                             format: .fragmentedMP4)
    }

    public func transcodeAudioSegment(data: Data,
                                      initializationData: Data?,
                                      originalCodec: String?,
                                      sourceURL: URL) async throws -> UPlayerTranscodedAudioSegment {

        let codec = try detectG711Codec(originalCodec: originalCodec)

        let extracted = try extractor.extractSamples(initializationData: initializationData,
                                                     fragmentData: data)

        guard !extracted.samples.isEmpty else {
            throw UPlayerErrorsList
                .aacEncodongFailed8
        }

        let totalBytes = extracted.samples.reduce(0) { $0 + $1.count }

        var pcm: [Int16] = []

        pcm.reserveCapacity(totalBytes)

        for sample in extracted.samples {
            pcm.append(contentsOf: decodeG711ToPCM(data: sample,
                                                   codec: codec))
        }

        guard !pcm.isEmpty else {
            throw UPlayerErrorsList.aacEncodongFailed8
        }

        log(
            """
            [g711 transcoder] source
            sampleCount=\(extracted.samples.count)
            totalG711Bytes=\(totalBytes)
            baseDecodeTime=\(extracted.baseDecodeTime)
            sourceSampleRate=\(sourceSampleRate)
            sourceDuration=\(Double(totalBytes) / sourceSampleRate)
            """,
            loggingLevel: .debug
        )
        
        let encoded = try aacEncoder.encodePCMToAAC(pcm: pcm,
                                                    sourceSampleRate: sourceSampleRate,
                                                    outputSampleRate: outputSampleRate,
                                                    channels: channels,
                                                    bitrate: bitrate)
        
        log(
            """
            [g711 transcoder] encoded
            packetCount=\(encoded.packets.count)
            totalAACFrames=\(encoded.duration)
            outputSampleRate=\(encoded.sampleRate)
            outputDuration=\(Double(encoded.duration) / Double(encoded.sampleRate))
            """,
            loggingLevel: .debug
        )
        
        guard !encoded.packets.isEmpty else {
            throw UPlayerErrorsList
                .aacEncodongFailed7
        }

        /*
         Convert source tfdt into the AAC track timescale.

         Example:
             G711 source timescale = 8000
             AAC output timescale   = 16000

             source tfdt 8000
                 -> AAC tfdt 16000
        */
        let outputBaseDecodeTime = UInt64((Double(extracted.baseDecodeTime) / sourceSampleRate) * outputSampleRate)

        let sequenceNumber = sequenceNumber(from: sourceURL)

        let fragment = try muxer.makeMediaSegment(encoded: encoded,
                                                  sequenceNumber: sequenceNumber,
                                                  baseDecodeTime: outputBaseDecodeTime)

        log(
            """
            [aac muxer] media
            sequenceNumber=\(sequenceNumber)
            baseDecodeTime=\(outputBaseDecodeTime)
            packetCount=\(encoded.packets.count)
            packetDuration=\(encoded.framesPerPacket)
            totalDuration=\(encoded.duration)
            sampleRate=\(encoded.sampleRate)
            """,
            loggingLevel: .debug
        )

        return UPlayerTranscodedAudioSegment(data: fragment,
                                             contentType: "audio/mp4",
                                             format: .fragmentedMP4)
    }
}

private extension UPlayerG711ToAACTranscoder {
    func sequenceNumber(from url: URL) -> UInt32 {
        guard let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "SequenceNumber"})?.value,
              let sequence = UInt32(value) else {

            return 1
        }

        return sequence
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
