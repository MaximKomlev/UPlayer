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

public protocol UPlayerAVAssetResourceLoaderDelegate: AnyObject {
    func getPlaylist(source: UPlayerAVAssetResourceLoaderProtocol, url: URL) -> String?
}

public protocol UPlayerAVAssetResourceLoaderProtocol: AVAssetResourceLoaderDelegate {
    var dataDelegate: UPlayerAVAssetResourceLoaderDelegate? { get set }
}

internal final class UPlayerAVAssetResourceLoader: NSObject, UPlayerAVAssetResourceLoaderProtocol {

    public weak var dataDelegate: UPlayerAVAssetResourceLoaderDelegate?
    public weak var audioTranscoder: UPlayerAudioTranscoderProtocol?

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                               shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {

        guard let url = loadingRequest.request.url else {
            loadingRequest.finishLoading(with: UPlayerErrorsList.assetLoadingFailed)
            return true
        }

        log("\(logScope) request, \(url.absoluteString)", loggingLevel: .info)

        if isAudioTranscodeRequest(url) {
            handleAudioTranscode(url: url, loadingRequest: loadingRequest)
            return true
        }

        handlePlaylist(url: url, loadingRequest: loadingRequest)
        return true
    }

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                               didCancel loadingRequest: AVAssetResourceLoadingRequest)
    {}
}

private extension UPlayerAVAssetResourceLoader {

    func isAudioTranscodeRequest(_ url: URL) -> Bool {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .contains { $0.name == "mode" && $0.value == "audio-transcode" } == true
    }

    func originalCodec(from url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == "codec" }?
            .value
    }

    func originalHTTPURL(from url: URL) -> URL? {
        guard var components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            return nil
        }

        components.scheme = "https"

        let queryItems = components.queryItems ?? []
        components.queryItems = queryItems.filter {
            $0.name != "mode" && $0.name != "codec"
        }

        return components.url
    }
    
    func handlePlaylist(url: URL,
                        loadingRequest: AVAssetResourceLoadingRequest) {
        guard let playlist = dataDelegate?.getPlaylist(source: self, url: url),
              let data = playlist.data(using: .utf8) else {
            loadingRequest.finishLoading(with: UPlayerErrorsList.assetLoadingFailed)
            return
        }

        respond(data: data,
                contentType: "application/vnd.apple.mpegurl",
                byteRangeSupported: false,
                loadingRequest: loadingRequest)
    }

    func handleAudioTranscode(url: URL,
                              loadingRequest: AVAssetResourceLoadingRequest) {
        Task { [weak self] in
            guard let self else { return }

            do {
                guard let sourceURL = self.originalHTTPURL(from: url) else {
                    throw UPlayerErrorsList.assetLoadingFailed
                }

                let originalCodec = self.originalCodec(from: url)

                let sourceData = try await self.download(url: sourceURL)

                let outputData: Data
                if let audioTranscoder = self.audioTranscoder {
                    outputData = try await audioTranscoder.transcodeAudioSegment(data: sourceData,
                                                                                 originalCodec: originalCodec,
                                                                                 sourceURL: sourceURL)
                } else {
                    outputData = sourceData
                }

                self.respond(data: outputData,
                             contentType: "audio/mp4",
                             byteRangeSupported: true,
                             loadingRequest: loadingRequest)
            } catch {
                loadingRequest.finishLoading(with: error)
            }
        }
    }

    func download(url: URL) async throws -> Data {
        let request = URLRequest(
            url: url,
            cachePolicy: .returnCacheDataElseLoad,
            timeoutInterval: 30
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw UPlayerErrorsList.invalidHTTPResponse
        }

        return data
    }

    func respond(data: Data,
                 contentType: String,
                 byteRangeSupported: Bool,
                 loadingRequest: AVAssetResourceLoadingRequest) {
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = contentType
            info.contentLength = Int64(data.count)
            info.isByteRangeAccessSupported = byteRangeSupported
        }

        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return
        }

        let requestedOffset = Int(dataRequest.requestedOffset)
        let currentOffset = Int(dataRequest.currentOffset)
        let startOffset = max(requestedOffset, currentOffset)

        guard startOffset >= 0, startOffset <= data.count else {
            loadingRequest.finishLoading(with: UPlayerErrorsList.assetLoadingFailed)
            return
        }

        let remaining = data.count - startOffset
        let responseLength = min(dataRequest.requestedLength, remaining)

        if responseLength > 0 {
            let subdata = data.subdata(in: startOffset ..< startOffset + responseLength)
            dataRequest.respond(with: subdata)
        }

        loadingRequest.finishLoading()
    }
}
