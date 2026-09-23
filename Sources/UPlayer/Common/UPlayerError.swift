//
//  UPlayerError.swift
//  UPlayer
//
//  Created by Max Komleu on 3/8/26.
//

import Foundation
import AVFoundation

internal let uplayerErrorDomain = "uplayerErrorDomain"

func makeError(errorCode: Int, errorMessage: String) -> NSError {
    return NSError(domain: uplayerErrorDomain,
                   code: errorCode,
                   userInfo: [NSLocalizedDescriptionKey: errorMessage])
}

public enum UPlayerError: LocalizedError {
    case undefined
    case nullReference
    case operationCanceled
    case unexpectedMimeTypeResponse
    case mpdParseNullData
    case mpdParseError
    case assetNotFoundError
    case invalidAssetURL
    case invalidAsset
    case assetLoadingFailed
    case aacEncodongFailed1
    case aacEncodongFailed2
    case aacEncodongFailed3
    case aacEncodongFailed4
    case aacEncodongFailed5
    case aacEncodongFailed6
    case aacEncodongFailed7
    case aacEncodongFailed8
    case missingManifest
    case unsupportedManifest
    case missingVideoRepresentation
    case missingSegmentTemplate
    case missingInitializationURL
    case invalidSegmentURL
    case invalidHTTPResponse(Int)
    case emptyDownload
    case missingMediaTrack(AVMediaType)
    case cannotCreateCompositionTrack(AVMediaType)
    case cannotCreateExportSession
    case exportFailed(Error?)
    case photoLibraryAccessDenied
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .undefined: return "undefined"
        case .nullReference: return "The reference is nil"
        case .operationCanceled: return "Operation canceled"
        case .unexpectedMimeTypeResponse: return "Unexpected Mime Type Response"
        case .mpdParseNullData: return "MPD data is nil"
        case .mpdParseError: return "MPD Parsing failed"
        case .assetNotFoundError: return "Asset not found"
        case .invalidAssetURL: return "Invalid asset URL"
        case .invalidAsset: return "Asset is not playable"
        case .assetLoadingFailed: return "Failed to load asset"
        case .aacEncodongFailed1: return "Failed to create PCM input format"
        case .aacEncodongFailed2: return "Failed to create AAC output format"
        case .aacEncodongFailed3: return "Failed to create AVAudioConverter"
        case .aacEncodongFailed4: return "Failed to create PCM buffer"
        case .aacEncodongFailed5: return "Missing PCM int16 channel data"
        case .aacEncodongFailed6: return "Failed to create compressed buffer"
        case .aacEncodongFailed7: return "AAC conversion failed"
        case .aacEncodongFailed8: return "Not supported codec"
        case .missingManifest: return "The asset does not contain a parsed DASH manifest."
        case .unsupportedManifest: return "Only DASH SegmentTemplate media is currently supported by UPlayerMediaExporter."
        case .missingVideoRepresentation: return "The DASH manifest does not contain a video representation."
        case .missingSegmentTemplate: return "The selected representation does not contain SegmentTemplate."
        case .missingInitializationURL: return "The representation does not contain an initialization URL."
        case .invalidSegmentURL: return "Failed to build a DASH segment URL."
        case .invalidHTTPResponse(let status): return "Media request failed with HTTP status \(status)."
        case .emptyDownload: return "Downloaded media data is empty."
        case .missingMediaTrack(let type): return "Downloaded media does not contain a \(type.rawValue) track."
        case .cannotCreateCompositionTrack(let type): return "Failed to create output \(type.rawValue) track."
        case .cannotCreateExportSession: return "Failed to create AVAssetExportSession."
        case .exportFailed(let error): return error?.localizedDescription ?? "MP4 export failed."
        case .photoLibraryAccessDenied: return "The user denied access to the photo library."
        case .cancelled: return "Export was cancelled."
        }
    }
}
