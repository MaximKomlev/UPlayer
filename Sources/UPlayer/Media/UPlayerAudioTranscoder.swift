//
//  UPlayerAudioTranscoder.swift
//  UPlayer
//
//  Created by Max Komleu on 4/29/26.
//

import Foundation
import UniformTypeIdentifiers

public enum UPlayerSupportedAudioCodecType: String, Codable, CustomStringConvertible {

    case aac
    case mp3
    case g711

    public var description: String {
        switch self {
        case .aac:
            return "AAC"

        case .mp3:
            return "MP3"

        case .g711:
            return "g711"
        }
    }
}

public struct UPlayerTranscodedAudioSegment {

    public let data: Data
    public let contentType: String

    public init(data: Data,
                contentType: String) {
        self.data = data
        self.contentType = contentType
    }
}

public protocol UPlayerAudioTranscoderProtocol: AnyObject {

    func transcodeAudioSegment(data: Data,
                               initializationData: Data?,
                               originalCodec: String?,
                               sourceURL: URL) async throws -> UPlayerTranscodedAudioSegment
}

public final class UPlayerAudioTranscoderFactory: UPlayerAudioTranscoderProtocol {

    private var transcoders = [UPlayerSupportedAudioCodecType: UPlayerAudioTranscoderProtocol]()

    public init() {}

    public func registerTranscoder(_ transcoder: UPlayerAudioTranscoderProtocol,
                                   forCodec type: UPlayerSupportedAudioCodecType) {
        transcoders[type] = transcoder
    }

    public func transcodeAudioSegment(data: Data,
                                      initializationData: Data?,
                                      originalCodec: String?,
                                      sourceURL: URL) async throws -> UPlayerTranscodedAudioSegment {

        let codec = originalCodec?
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""

        let requiresG711Transcoding =
            codec.contains("alaw") ||
            codec.contains("pcma") ||
            codec.contains("g711a") ||
            codec.contains("ulaw") ||
            codec.contains("mulaw") ||
            codec.contains("pcmu") ||
            codec.contains("g711u")

        if requiresG711Transcoding {
            guard let transcoder = transcoders[.g711] else {
                // Do NOT return the original G711 data here.
                //
                // The generated HLS master advertises AAC-LC,
                // therefore returning G711 would create a codec mismatch.
                throw UPlayerErrorsList.aacEncodongFailed8
            }

            return try await transcoder.transcodeAudioSegment(
                data: data,
                initializationData: initializationData,
                originalCodec: originalCodec,
                sourceURL: sourceURL
            )
        }

        // Already-supported audio is passed through.
        return UPlayerTranscodedAudioSegment(data: data,
                                             contentType: UTType(filenameExtension: "aac")?.identifier
                                             ?? "public.aac-audio")
    }
}
