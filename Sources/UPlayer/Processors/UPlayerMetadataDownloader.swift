//
//  UPlayerMetadataDownloader.swift
//  UPlayer
//
//  Created by Max Komleu on 2/23/26.
//

import Combine
import Foundation
import AVFoundation

private let logScope = "[mpd downloading]"

@objcMembers public final class UPlayerMetadataDownloader: UPlayerAssetProcessorProtocol {
    
    // MARK: Fields
    
    private let isRunningPrivate = SyncProperty(value: false)
    private var isTaskCanceled = SyncProperty<Bool>(value: false)

    private var task = SyncProperty<URLSessionDataTask?>(value: nil)
    
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .useProtocolCachePolicy
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()
    
    // MARK: Constructors/Destructor
    
    public init(id: String) {
        self.id = id
    }
    
    // MARK: UPlayerProcessorProtocol

    public let id: String

    public var isRunning: Bool {
        isRunningPrivate.value
    }

    public func process(asset: UPlayerAssetProtocol) -> AnyPublisher<UPlayerAssetProtocol, Error> {
        isTaskCanceled.set { $0 = false }
        isRunningPrivate.set { $0 = true }

        log("\(logScope) started, url: \(asset.url)", loggingLevel: .debug)

        // Fast path: known by extension
        switch asset.url.pathExtension.lowercased() {
        case "mpd":
            asset.type = .mpd(0)
            return download(asset: asset)
                .handleEvents(
                    receiveCompletion: { [weak self] completion in
                        if case .finished = completion {
                            self?.isRunningPrivate.set { $0 = false }
                        }
                    }
                )
                .eraseToAnyPublisher()

        case "m3u8":
            asset.type = .hls
            asset.httpMetadata = UPlayerAssetHttpData(url: asset.url)
            isRunningPrivate.set { $0 = false }
            return Just(asset)
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()

        case "mp4":
            asset.type = .mp4
            asset.httpMetadata = UPlayerAssetHttpData(url: asset.url)
            isRunningPrivate.set { $0 = false }
            return Just(asset)
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()

        default:
            break
        }

        return detectMediaTypeWithRange(asset: asset)
            .flatMap { [weak self] asset -> AnyPublisher<UPlayerAssetProtocol, Error> in
                guard let self else {
                    let error = UPlayerErrorsList.nullReference
                    log("\(logScope) failed, \(error), url: \(asset.url)", loggingLevel: .error)
                    return Fail(error: error).eraseToAnyPublisher()
                }
                return self.download(asset: asset)
            }
            .handleEvents(
                receiveCompletion: { [weak self] completion in
                    if case .finished = completion {
                        self?.isRunningPrivate.set { $0 = false }
                    }
                }
            )
            .eraseToAnyPublisher()
    }
    
    public func cancel() {
        isTaskCanceled.set({ $0 = true })
        task.value?.cancel()
    }
    
    // MARK: Detect Media Type
    
    private func detectMediaTypeWithRange(asset: UPlayerAssetProtocol) -> AnyPublisher<UPlayerAssetProtocol, Error> {
        
        Future { [weak self] promise in
            
            guard let self else {
                let error = UPlayerErrorsList.nullReference
                log("\(logScope) failed, \(error)", loggingLevel: .error)
                promise(.failure(error))
                return
            }
            
            if self.isTaskCanceled.value {
                let error = UPlayerErrorsList.operationCanceled
                log("\(logScope) failed, \(error)", loggingLevel: .error)
                promise(.failure(error))
                return
            }

            var request = URLRequest(url: asset.url)
            request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
            
            let task = session.dataTask(with: request) { data, response, error in
                
                if let error = error {
                    promise(.failure(error))
                    return
                }
       
                if self.isTaskCanceled.value {
                    let error = UPlayerErrorsList.operationCanceled
                    log("\(logScope) failed, \(error)", loggingLevel: .error)
                    promise(.failure(error))
                    return
                }

                guard let http = response as? HTTPURLResponse else {
                    let error = UPlayerErrorsList.invalidHTTPResponse
                    log("\(logScope) failed, \(error)", loggingLevel: .error)
                    promise(.failure(error))
                    return
                }
                
                guard (200...299).contains(http.statusCode),
                      let data = data else {
                    
                    let description = HTTPURLResponse
                        .localizedString(forStatusCode: http.statusCode)
                    
                    promise(.failure(
                        makeError(
                            errorCode: http.statusCode,
                            errorMessage: description
                        )
                    ))
                    return
                }
                
                let mediaType = self.detectMediaType(
                    response: response,
                    data: data,
                    url: asset.url
                )
                
                asset.type = mediaType
                promise(.success(asset))
            }
            
            self.task.set({ $0 = task })
            self.task.value?.resume()
        }
        .eraseToAnyPublisher()
    }
    
    // MARK: Download (Only for MPD)
    
    public func download(asset: UPlayerAssetProtocol) -> AnyPublisher<UPlayerAssetProtocol, Error> {
        
        // No download needed
        switch asset.type {
        case .hls, .mp4:
            asset.httpMetadata = UPlayerAssetHttpData(url: asset.url)
            return Just(asset)
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        default:
            break
        }
        
        // Only MPD requires full download
        switch asset.type {
        case .mpd:
            break
        default:
            let error = UPlayerErrorsList.unexpectedMimeTypeResponse
            log("\(logScope) failed, \(error)", loggingLevel: .error)
            return Fail(error: error).eraseToAnyPublisher()
        }
        
        return Future { [weak self] promise in
            
            guard let self else {
                let error = UPlayerErrorsList.nullReference
                log("\(logScope) failed, \(error)", loggingLevel: .error)
                promise(.failure(error))
                return
            }
            
            if self.isTaskCanceled.value {
                let error = UPlayerErrorsList.operationCanceled
                log("\(logScope) failed, \(error)", loggingLevel: .error)
                promise(.failure(error))
                return
            }
            

            log("\(logScope) download data for url, \(asset.url)", loggingLevel: .debug)
            let task = session.dataTask(with: asset.url) { data, response, error in
                
                if self.isTaskCanceled.value {
                    let error = UPlayerErrorsList.operationCanceled
                    log("\(logScope) failed, \(error)", loggingLevel: .error)
                    promise(.failure(error))
                    return
                }

                if let error = error {
                    promise(.failure(error))
                    return
                }
                
                guard let http = response as? HTTPURLResponse,
                      (200...299).contains(http.statusCode),
                      let data = data else {
                    
                    let error = UPlayerErrorsList.invalidHTTPResponse
                    log("\(logScope) failed, \(error)", loggingLevel: .error)
                    promise(.failure(error))
                    return
                }
                
                log("\(logScope) succeed, url: \(asset.url)", loggingLevel: .debug)

                asset.mpdMetadata = UPlayerAssetMPDData(rawData: data)
                promise(.success(asset))
            }
            
            self.task.set({ $0 = task })
            self.task.value?.resume()
        }
        .eraseToAnyPublisher()
    }
    
    // MARK: Media Type Detection
    
    private func detectMediaType(response: URLResponse?,
                                 data: Data?,
                                 url: URL?) -> UPlayerAssetType {
        
        // MIME
        if let http = response as? HTTPURLResponse,
           let mime = http.mimeType?.lowercased() {
            
            if mime.contains("mpegurl") {
                return .hls
            }
            if mime == "application/dash+xml" {
                return .mpd(0)
            }
            if mime == "video/mp4" {
                return .mp4
            }
        }
        
        // Extension
        if let ext = url?.pathExtension.lowercased() {
            switch ext {
            case "m3u8": return .hls
            case "mpd":  return .mpd(0)
            case "mp4":  return .mp4
            default: break
            }
        }
        
        guard let data else {
            return .unknown
        }
        
        // HLS
        if let text = String(data: data.prefix(200), encoding: .utf8),
           text.hasPrefix("#EXTM3U") {
            return .hls
        }
        
        // MPD
        if let text = String(data: data.prefix(500), encoding: .utf8),
           text.contains("<MPD") {
            return .mpd(0)
        }
        
        // MP4
        if data.count > 12 {
            let boxData = data.subdata(in: 4..<12)
            if let boxString = String(data: boxData, encoding: .ascii),
               boxString.contains("ftyp") {
                return .mp4
            }
        }
        
        return .unknown
    }
}
