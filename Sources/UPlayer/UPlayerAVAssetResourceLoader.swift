//
//  UPlayerAVAssetResourceLoader.swift
//  UPlayer
//
//  Created by Max Komleu on 2/23/26.
//

import AVFoundation
import Foundation
import UniformTypeIdentifiers

private let logScope = "[avassetresourceloader]"

public protocol UPlayerAVAssetResourceLoaderDelegate: AnyObject {
    func getPlaylist(source: UPlayerAVAssetResourceLoaderProtocol, url: URL) -> String?
}

public protocol UPlayerAVAssetResourceLoaderProtocol: AVAssetResourceLoaderDelegate {
    var dataDelegate: UPlayerAVAssetResourceLoaderDelegate? { get set }
}

internal final class UPlayerAVAssetResourceLoader: NSObject, UPlayerAVAssetResourceLoaderProtocol {

    public weak var dataDelegate: UPlayerAVAssetResourceLoaderDelegate?

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                               shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {

        log("\(logScope) request, \(loadingRequest.request.url?.absoluteString ?? "nil")", loggingLevel: .info)

        guard let url = loadingRequest.request.url else {
            loadingRequest.finishLoading(with: UPlayerErrorsList.assetLoadingFailed)
            return true
        }

        guard let playlist = dataDelegate?.getPlaylist(source: self, url: url) else {
            loadingRequest.finishLoading(with: UPlayerErrorsList.assetLoadingFailed)
            return true
        }

        //log("\(logScope) playlist, \(playlist)")

        guard let data = playlist.data(using: .utf8) else {
            loadingRequest.finishLoading(with: UPlayerErrorsList.assetLoadingFailed)
            return true
        }

        if let info = loadingRequest.contentInformationRequest {
            info.contentType = contentType(url: url)
            info.contentLength = Int64(data.count)
            info.isByteRangeAccessSupported = false
        }
        
        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return true
        }

        let requestedOffset = Int(dataRequest.requestedOffset)
        let currentOffset = Int(dataRequest.currentOffset)
        let startOffset = max(requestedOffset, currentOffset)

        guard startOffset >= 0, startOffset <= data.count else {
            loadingRequest.finishLoading(with: UPlayerErrorsList.assetLoadingFailed)
            return true
        }

        let remaining = data.count - startOffset
        let responseLength = min(dataRequest.requestedLength, remaining)

        if responseLength > 0 {
            let subdata = data.subdata(in: startOffset ..< (startOffset + responseLength))
            dataRequest.respond(with: subdata)
        }

        loadingRequest.finishLoading()
        return true
    }

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                               didCancel loadingRequest: AVAssetResourceLoadingRequest) {
    }
    
    private func contentType(url: URL) -> String {
        let ext = url.pathExtension.lowercased()

        let contentType: String
        switch ext {
        case "m3u8", "mpd":
            contentType = "application/vnd.apple.mpegurl"
        case "mp4":
            contentType = "video/mp4"
        case "m4s":
            contentType = "video/iso.segment"
        default:
            contentType = "application/octet-stream"
        }

        return contentType
    }
}
