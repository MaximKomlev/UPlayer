//
//  UPlayerAudioTranscoder.swift
//  UPlayer
//
//  Created by Max Komleu on 4/29/26.
//

import Foundation

public enum UPlayerSupportedAudioCodecType: String, Codable, CustomStringConvertible {
    case aac
    case mp3
    case g711
    
    public var description: String {
        switch self {
        case .aac:
            "AAC"
        case .mp3:
            "MP3"
        case .g711:
            "g711"
        default:
            ""
        }
    }
}

public protocol UPlayerAudioTranscoderProtocol: AnyObject {
    func transcodeAudioSegment(data: Data,
                               originalCodec: String?,
                               sourceURL: URL) async throws -> Data
}

public final class UPlayerAudioTranscoderFactory: UPlayerAudioTranscoderProtocol {
    
    private var transcoders = [UPlayerSupportedAudioCodecType: UPlayerAudioTranscoderProtocol]()
    
    public init() {}
    
    public func registerTranscoder(_ transcoder: UPlayerAudioTranscoderProtocol, forCodec type: UPlayerSupportedAudioCodecType) {
        transcoders[type] = transcoder
    }
    
    public func transcodeAudioSegment(data: Data, originalCodec: String?, sourceURL: URL) async throws -> Data {
        var targetCodec: UPlayerSupportedAudioCodecType = .aac
        let originalCodec = originalCodec ?? "g711u"
        if originalCodec.contains("alaw") ||
            originalCodec.contains("pcma") ||
            originalCodec.contains("g711a") ||
            originalCodec.contains("ulaw") ||
            originalCodec.contains("mulaw") ||
            originalCodec.contains("pcmu") ||
            originalCodec.contains("g711u") {
            targetCodec = .g711
        }
        
        guard let transcoder = transcoders[targetCodec] else {
            return data
        }
        
        return try await transcoder.transcodeAudioSegment(data: data, originalCodec: originalCodec, sourceURL: sourceURL)
    }
}
