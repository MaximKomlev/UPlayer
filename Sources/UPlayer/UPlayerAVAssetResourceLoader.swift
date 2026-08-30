//
// UPlayerAVAssetResourceLoader.swift
// UPlayer
//
// Created by Max Komleu on 2/23/26.
//

import Foundation
import AVFoundation
import UniformTypeIdentifiers

private let logScope = "[avassetresourceloader]"

public protocol UPlayerAVAssetResourceLoaderDelegate: AnyObject {
    func getPlaylist(source: UPlayerAVAssetResourceLoaderProtocol, url: URL) -> String?
}

public protocol UPlayerAVAssetResourceLoaderTranscodingDelegate: AnyObject {
    func getAudioTranscoder(source: UPlayerAVAssetResourceLoaderProtocol) -> UPlayerAudioTranscoderProtocol?
}

public protocol UPlayerAVAssetResourceLoaderProtocol: AVAssetResourceLoaderDelegate {
    var dataDelegate: UPlayerAVAssetResourceLoaderDelegate? { get set }
    var transcoderDelegate: UPlayerAVAssetResourceLoaderTranscodingDelegate? { get set }
}

internal final class UPlayerAVAssetResourceLoader: NSObject, UPlayerAVAssetResourceLoaderProtocol {
    
    public weak var dataDelegate: UPlayerAVAssetResourceLoaderDelegate?
    public weak var transcoderDelegate: UPlayerAVAssetResourceLoaderTranscodingDelegate?
    public var mediaRequestHeader: [String: Any]?
    private let transcodedCache = NSCache<NSString, NSData>()
    
    override init() {
        super.init()
        transcodedCache.countLimit = 64
        transcodedCache.totalCostLimit = 32 * 1024 * 1024
    }
    
    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        
        guard let url = loadingRequest.request.url else {
            loadingRequest.finishLoading(with: UPlayerErrorsList.assetLoadingFailed)
            return true
        }
        
        log("\(logScope) request, \(url.absoluteString)", loggingLevel: .info)
        
        switch requestMode(url) {
        case "audio-transcode-init":
            handleAudioInitialization(
                url: url,
                loadingRequest: loadingRequest)
        case "audio-transcode":
            handleAudioTranscode(
                url: url,
                loadingRequest: loadingRequest)
        default:
            handlePlaylist(url: url, loadingRequest: loadingRequest)
        }
        return true
    }
    
    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {}
}

extension UPlayerAVAssetResourceLoader {
    fileprivate func requestMode(_ url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first {
            $0.name == "mode"
        }?.value
    }
    
    fileprivate func originalCodec(from url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first {
            $0.name == "codec"
        }?.value
    }
    
    private func originalHTTPURL(from url: URL) -> URL? {
        let original = url.absoluteString
        guard let schemeRange = original.range(of: "://") else {
            return nil
        }
        
        let value = "https://" + original[schemeRange.upperBound...]
        guard let questionMark = value.firstIndex(of: "?") else {
            return URL(string: value)
        }
        
        let base = String(value[..<questionMark])
        let queryStart = value.index(after: questionMark)
        let rawQuery = String(value[queryStart...])
        
        let filteredQuery = rawQuery.split(separator: "&", omittingEmptySubsequences: false).filter { rawItem in
            let name = rawItem.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            return name != "mode" && name != "codec"
        }.joined(separator: "&")
        
        let result = filteredQuery.isEmpty ? base : "\(base)?\(filteredQuery)"
        return URL(string: result)
    }
}

extension UPlayerAVAssetResourceLoader {
    fileprivate func handleAudioInitialization(url: URL, loadingRequest: AVAssetResourceLoadingRequest) {
        Task { [weak self] in
            guard let self else {
                return
            }
            
            do {
                let cacheKey = "init|\(originalCodec(from: url) ?? "")" as NSString
                guard let realURL = originalHTTPURL(from: url) else {
                    throw UPlayerErrorsList.assetLoadingFailed
                }
                
                if let cached = transcodedCache.object(forKey: cacheKey) {
                    respondRedirectedMedia(data: cached as Data,
                                           realURL: realURL,
                                           mimeType: "audio/mp4",
                                           loadingRequest: loadingRequest)
                    return
                }
                
                guard let transcoder = transcoderDelegate?.getAudioTranscoder(source: self) else {
                    throw UPlayerErrorsList.aacEncodongFailed8
                }
                
                let codec = originalCodec(from: url)
                guard let result = try await transcoder.makeInitializationSegment(originalCodec: codec) else {
                    throw UPlayerErrorsList.aacEncodongFailed7
                }
                
                guard result.format == .fragmentedMP4, !result.data.isEmpty else {
                    throw UPlayerErrorsList.aacEncodongFailed7
                }
                
                log("\(logScope) AAC init generated codec=\(codec ?? "unknown") bytes=\(result.data.count) format=\(result.format) contentType=\(result.contentType)",
                    loggingLevel: .debug)
                
                dumpTopLevelMP4Boxes(result.data, prefix: "AAC init")
                
                transcodedCache.setObject(result.data as NSData,
                                          forKey: cacheKey,
                                          cost: result.data.count)
                respondRedirectedMedia(data: result.data,
                                       realURL: realURL,
                                       mimeType: "audio/mp4",
                                       loadingRequest: loadingRequest)
            } catch {
                log("\(logScope) init transcoding failed: \(error)", loggingLevel: .error)
                loadingRequest.finishLoading(with: error)
            }
        }
    }
}

extension UPlayerAVAssetResourceLoader {
    fileprivate func handleAudioTranscode(url: URL, loadingRequest: AVAssetResourceLoadingRequest) {
        Task { [weak self] in
            guard let self else {
                return
            }
            
            do {
                guard let sourceURL = originalHTTPURL(from: url) else {
                    throw UPlayerErrorsList.assetLoadingFailed
                }
            
                let cacheKey = url.absoluteString as NSString
                if let cached = transcodedCache.object(forKey: cacheKey) {
                    log("\(logScope) audio cache hit", loggingLevel: .debug)
                    
                    respondRedirectedMedia(data: cached as Data,
                                           realURL: sourceURL,
                                           mimeType: "audio/mp4",
                                           loadingRequest: loadingRequest)
                    return
                }
                
                guard let transcoder = transcoderDelegate?.getAudioTranscoder(source: self) else {
                    throw UPlayerErrorsList.aacEncodongFailed8
                }
                
                let codec = originalCodec(from: url)
                log("\(logScope) transcoding request: \(url.absoluteString)", loggingLevel: .debug)
                log("\(logScope) original HTTP URL: \(sourceURL.absoluteString)", loggingLevel: .debug)
                
                let sourceData = try await download(url: sourceURL)
                let result = try await transcoder.transcodeAudioSegment(data: sourceData,
                                                                        initializationData: nil,
                                                                        originalCodec: codec,
                                                                        sourceURL: sourceURL)
                guard result.format == .fragmentedMP4, !result.data.isEmpty else {
                    throw UPlayerErrorsList.aacEncodongFailed7
                }
                
                dumpTopLevelMP4Boxes(result.data,
                                     prefix: "AAC media")
                
                log("\(logScope) G711 fMP4 \(sourceData.count) -> AAC fMP4 \(result.data.count)", loggingLevel: .debug)
                
                transcodedCache.setObject(result.data as NSData,
                                          forKey: cacheKey,
                                          cost: result.data.count)
                
                respondRedirectedMedia(data: result.data,
                                       realURL: sourceURL,
                                       mimeType: "audio/mp4",
                                       loadingRequest: loadingRequest)
            } catch {
                log("\(logScope) audio transcoding for \(url.absoluteString) failed, \(error)", loggingLevel: .error)
                loadingRequest.finishLoading(with: error)
            }
        }
    }
}

extension UPlayerAVAssetResourceLoader {
    fileprivate func download(url: URL) async throws -> Data {
        var request = URLRequest(url: url,
                                 cachePolicy: .returnCacheDataElseLoad,
                                 timeoutInterval: 30)
        
        for (field, value) in mediaRequestHeader ?? [:]{
            request.setValue(String(describing: value), forHTTPHeaderField: field)
        }
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let http = response as? HTTPURLResponse else {
            throw UPlayerErrorsList.invalidHTTPResponse
        }
        
        guard (200...299).contains(http.statusCode) else {
            log("\(logScope) HTTP \(http.statusCode), \(url)", loggingLevel: .error)
            throw UPlayerErrorsList.invalidHTTPResponse
        }
        
        log("""
            \(logScope) source download succeeded
            status=\(http.statusCode)
            bytes=\(data.count)
            contentType=\(http.value(forHTTPHeaderField: "Content-Type") ?? "unknown")
            url=\(url.absoluteString)
            """,
            loggingLevel: .debug)
        return data
    }
}

extension UPlayerAVAssetResourceLoader {
    fileprivate func handlePlaylist(url: URL, loadingRequest: AVAssetResourceLoadingRequest) {
        guard let playlist = dataDelegate?.getPlaylist(source: self, url: url),
            let data = playlist.data(using: .utf8) else {
            loadingRequest.finishLoading(with: UPlayerErrorsList.assetLoadingFailed)
            return
        }
        
        respond(data: data, uti: UTType(filenameExtension: "m3u8")?.identifier ?? "public.m3u-playlist",
                mimeType: "application/vnd.apple.mpegurl",
                byteRangeSupported: false,
                loadingRequest: loadingRequest)
    }
}

extension UPlayerAVAssetResourceLoader {
    fileprivate func respond(data: Data, uti: String, mimeType: String, byteRangeSupported: Bool, loadingRequest: AVAssetResourceLoadingRequest) {
        if let info = loadingRequest.contentInformationRequest{
            info.contentType = uti
            info.contentLength = Int64(data.count)
            info.isByteRangeAccessSupported = byteRangeSupported
        }
        
        if let requestURL = loadingRequest.request.url {
            loadingRequest.response = HTTPURLResponse(url: requestURL,
                                                      statusCode: 200,
                                                      httpVersion: "HTTP/1.1",
                                                      headerFields: [
                                                        "Content-Type": mimeType,
                                                        "Content-Length": "\(data.count)",
                                                        "Accept-Ranges": byteRangeSupported ? "bytes" : "none"
                                                      ])
        }
        
        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return
        }
        
        log("""
            \(logScope) respond
            url=\(loadingRequest.request.url?.absoluteString ?? "nil")
            totalBytes=\(data.count)
            requestedOffset=\(dataRequest.requestedOffset)
            currentOffset=\(dataRequest.currentOffset)
            requestedLength=\(dataRequest.requestedLength)
            requestsAllDataToEnd=\(dataRequest.requestsAllDataToEndOfResource)
            """,
            loggingLevel: .debug)
        
        let start = max(Int(dataRequest.requestedOffset), Int(dataRequest.currentOffset))
        
        guard start >= 0,
            start <= data.count else {
            loadingRequest.finishLoading(with:UPlayerErrorsList.assetLoadingFailed)
            return
        }
        
        let available = data.count - start
        let requested = dataRequest.requestedLength
        let length = min(requested, available)
        if length > 0 {
            dataRequest.respond(with: data.subdata(in: start..<(start + length)))
        }
        
        loadingRequest.finishLoading()
    }
}

private func dumpTopLevelMP4Boxes(_ data: Data, prefix: String) {
    var offset = 0
    while offset + 8 <= data.count {
        let size = Int(UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3]))
        
        let typeData = data.subdata(in: offset + 4..<offset + 8)
        let type = String(data: typeData, encoding: .ascii) ?? "????"
        
        log("\(logScope) \(prefix) box \(type), offset=\(offset), size=\(size)", loggingLevel: .debug)
        
        guard size >= 8,
                offset + size <= data.count else {
            log("\(logScope) \(prefix) invalid box size \(size) at \(offset)", loggingLevel: .error)
            break
        }
        
        offset += size
    }
    
    if offset != data.count {
        log("\(logScope) \(prefix) unparsed trailing bytes=\(data.count - offset)", loggingLevel: .error)
    }
}

extension UPlayerAVAssetResourceLoader {
    fileprivate func respondRedirectedMedia(data: Data, realURL: URL, mimeType: String, loadingRequest: AVAssetResourceLoadingRequest) {
        var redirectRequest = URLRequest(url: realURL,
                                         cachePolicy: .returnCacheDataElseLoad,
                                         timeoutInterval: 30)
        
        for (field, value) in mediaRequestHeader ?? [:] {
            redirectRequest.setValue(String(describing: value), forHTTPHeaderField: field)
        }

        loadingRequest.redirect = redirectRequest
        let response = HTTPURLResponse(url: realURL,
                                       statusCode: 302,
                                       httpVersion: nil,
                                       headerFields: nil)
        
        loadingRequest.response = response
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = mimeType
            info.contentLength = Int64(data.count)
            info.isByteRangeAccessSupported = false
        }

        log("""
            \(logScope) redirected media response
            requestURL=\(loadingRequest.request.url?.absoluteString ?? "nil")
            redirectURL=\(realURL.absoluteString)
            status=302
            mimeType=\(mimeType)
            bytes=\(data.count)
            requestedOffset=\(loadingRequest.dataRequest?.requestedOffset ?? 0)
            currentOffset=\(loadingRequest.dataRequest?.currentOffset ?? 0)
            requestedLength=\(loadingRequest.dataRequest?.requestedLength ?? 0)
            requestsAllDataToEnd=\(loadingRequest.dataRequest?.requestsAllDataToEndOfResource ?? false)
            """,
            loggingLevel: .debug)
        
        loadingRequest.dataRequest?.respond(with: data)
        loadingRequest.finishLoading()
    }
}
