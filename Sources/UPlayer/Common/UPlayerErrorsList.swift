//
//  UPlayerErrorsList.swift
//  UPlayer
//
//  Created by Max Komleu on 3/8/26.
//

import Foundation

internal let uplayerErrorDomain = "uplayerErrorDomain"

func makeError(errorCode: Int, errorMessage: String) -> NSError {
    return NSError(domain: uplayerErrorDomain,
                   code: errorCode,
                   userInfo: [NSLocalizedDescriptionKey: errorMessage])
}

class UPlayerErrorsList: AnyObject {
    public static let undefined = makeError(errorCode: -1, errorMessage: "undefined")
    public static let nullReference = makeError(errorCode: -2, errorMessage: "The reference is nil")
    public static let operationCanceled = makeError(errorCode: -3, errorMessage: "Operation canceled")
    public static let invalidHTTPResponse = makeError(errorCode: -4, errorMessage: "Invalid HTTP Response")
    public static let unexpectedMimeTypeResponse = makeError(errorCode: -5, errorMessage: "Unexpected Mime Type Response")
    public static let mpdParseNullData = makeError(errorCode: -6, errorMessage: "MPD data is nil")
    public static let mpdParseError = makeError(errorCode: -7, errorMessage: "MPD Parsing failed")
    public static let assetNotFoundError = makeError(errorCode: -8, errorMessage: "Asset not found")
    public static let invalidAssetURL = makeError(errorCode: -9, errorMessage: "Invalid asset URL")
    public static let invalidAsset = makeError(errorCode: -10, errorMessage: "Asset is not playable")
    public static let assetLoadingFailed = makeError(errorCode: -11, errorMessage: "Failed to load asset")
    public static let aacEncodongFailed1 = makeError(errorCode: -12, errorMessage: "Failed to create PCM input format")
    public static let aacEncodongFailed2 = makeError(errorCode: -13, errorMessage: "Failed to create AAC output format")
    public static let aacEncodongFailed3 = makeError(errorCode: -14, errorMessage: "Failed to create AVAudioConverter")
    public static let aacEncodongFailed4 = makeError(errorCode: -15, errorMessage: "Failed to create PCM buffer")
    public static let aacEncodongFailed5 = makeError(errorCode: -16, errorMessage: "Missing PCM int16 channel data")
    public static let aacEncodongFailed6 = makeError(errorCode: -17, errorMessage: "Failed to create compressed buffer")
    public static let aacEncodongFailed7 = makeError(errorCode: -18, errorMessage: "AAC conversion failed")
    public static let aacEncodongFailed8 = makeError(errorCode: -19, errorMessage: "Not supported codec")
}
