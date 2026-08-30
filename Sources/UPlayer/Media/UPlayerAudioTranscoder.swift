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

public enum UPlayerTranscodedAudioFormat {
    case fragmentedMP4
    case adts
}

public struct UPlayerTranscodedAudioSegment {

    public let data: Data
    public let contentType: String
    public let format: UPlayerTranscodedAudioFormat

    public init(data: Data,
                contentType: String,
                format: UPlayerTranscodedAudioFormat) {
        self.data = data
        self.contentType = contentType
        self.format = format
    }
}

public protocol UPlayerAudioTranscoderProtocol: AnyObject {

    func makeInitializationSegment(originalCodec: String?) async throws -> UPlayerTranscodedAudioSegment?

    func transcodeAudioSegment(data: Data,
                               initializationData: Data?,
                               originalCodec: String?,
                               sourceURL: URL) async throws -> UPlayerTranscodedAudioSegment
}

public final class UPlayerAudioTranscoderFactory: UPlayerAudioTranscoderProtocol {

    private var transcoders = [
        UPlayerSupportedAudioCodecType: UPlayerAudioTranscoderProtocol
    ]()

    public init() {}

    public func registerTranscoder(_ transcoder: UPlayerAudioTranscoderProtocol, forCodec type: UPlayerSupportedAudioCodecType) {
        transcoders[type] = transcoder
    }

    public func makeInitializationSegment(originalCodec: String?) async throws -> UPlayerTranscodedAudioSegment? {

        guard let type = codecType(originalCodec) else {
            return nil
        }

        guard let transcoder = transcoders[type] else {
            if type == .g711 {
                throw UPlayerErrorsList.aacEncodongFailed8
            }
            return nil
        }

        return try await transcoder.makeInitializationSegment(originalCodec: originalCodec)
    }

    public func transcodeAudioSegment(data: Data,
                                      initializationData: Data?,
                                      originalCodec: String?,
                                      sourceURL: URL) async throws -> UPlayerTranscodedAudioSegment {

        guard let type = codecType(originalCodec) else {
            return UPlayerTranscodedAudioSegment(data: data,
                                                 contentType: "audio/mp4",
                                                 format: .fragmentedMP4)
        }

        guard let transcoder = transcoders[type] else {
            if type == .g711 {
                throw UPlayerErrorsList.aacEncodongFailed8
            }

            return UPlayerTranscodedAudioSegment(data: data,
                                                 contentType: "audio/mp4",
                                                 format: .fragmentedMP4)
        }

        return try await transcoder.transcodeAudioSegment(data: data,
                                                          initializationData: initializationData,
                                                          originalCodec: originalCodec,
                                                          sourceURL: sourceURL)
    }
}

private extension UPlayerAudioTranscoderFactory {
    func codecType(_ originalCodec: String?) -> UPlayerSupportedAudioCodecType? {

        let codec = originalCodec?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if codec.contains("alaw") ||
            codec.contains("pcma") ||
            codec.contains("g711a") ||
            codec.contains("ulaw") ||
            codec.contains("mulaw") ||
            codec.contains("pcmu") ||
            codec.contains("g711u") {

            return .g711
        }

        if codec.hasPrefix("mp4a.") {
            return .aac
        }

        return nil
    }
}

public extension UPlayerAudioTranscoderProtocol {
    func makeInitializationSegment(originalCodec: String?) async throws -> UPlayerTranscodedAudioSegment? {
        nil
    }
}
