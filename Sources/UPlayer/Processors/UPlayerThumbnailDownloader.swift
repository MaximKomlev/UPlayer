//
//  UPlayerThumbnailDownloader.swift
//  UPlayer
//
//  Created by Max Komleu on 4/27/26.
//

import Combine
import Foundation
import CoreGraphics

private let logScope = "[thumbnail downloading]"

public final class UPlayerThumbnailDownloader: UPlayerAssetProcessorProtocol {

    private let isRunningPrivate = SyncProperty(value: false)
    private var isTaskCanceled = SyncProperty<Bool>(value: false)

    public let id: String

    private let liveSafetyDelaySprites = 3
    private let liveWindowSpriteCount = 6

    public init(id: String) {
        self.id = id
    }

    public var isRunning: Bool {
        isRunningPrivate.value
    }

    public func process(asset: UPlayerAssetProtocol) -> AnyPublisher<UPlayerAssetProtocol, Error> {
        isTaskCanceled.set { $0 = false }
        isRunningPrivate.set { $0 = true }

        return Future { [weak self] promise in
            guard let self else {
                promise(.failure(UPlayerErrorsList.nullReference))
                return
            }

            log("\(logScope) started, url: \(asset.url)", loggingLevel: .debug)

            Task {
                defer {
                    self.isRunningPrivate.set { $0 = false }
                }

                do {
                    if self.isTaskCanceled.value {
                        throw UPlayerErrorsList.operationCanceled
                    }

                    guard let manifest = asset.mpdMetadata?.manifest else {
                        promise(.success(asset))
                        return
                    }

                    guard let track = self.selectThumbnailTrack(from: manifest) else {
                        promise(.success(asset))
                        return
                    }

                    let cues: [DASHThumbnailCue]

                    switch manifest.type {
                    case .staticVOD:
                        let totalDuration =
                            manifest.mediaPresentationDuration ??
                            manifest.periods.first?.duration ??
                            track.duration

                        cues = self.buildVODCues(track: track,
                                                 totalDuration: totalDuration)

                    case .dynamicLive:
                        cues = self.buildLiveCues(manifest: manifest,
                                                  track: track,
                                                  now: Date())
                    }

                    let urls = self.spriteURLs(from: cues)

                    var sprites: [URL: UPlayerThumbnailSprite] = [:]

                    for url in urls {
                        if self.isTaskCanceled.value {
                            throw UPlayerErrorsList.operationCanceled
                        }

                        let data = try await self.download(url: url)
                        sprites[url] = UPlayerThumbnailSprite(url: url, data: data)
                    }

                    asset.thumbnailMetadata = UPlayerAssetThumbnailData(track: track,
                                                                        sprites: sprites,
                                                                        cues: cues)

                    log("\(logScope) succeed, url: \(asset.url)", loggingLevel: .debug)
                    promise(.success(asset))
                } catch {
                    log("\(logScope) failed, \(error), url: \(asset.url)", loggingLevel: .error)
                    promise(.success(asset))
                }
            }
        }
        .eraseToAnyPublisher()
    }

    public func cancel() {
        isTaskCanceled.set { $0 = true }
    }
}

private extension UPlayerThumbnailDownloader {
    
    func selectThumbnailTrack(from manifest: DASHManifest) -> DASHThumbnailTrack? {
        return manifest.thumbnailTracks
            .sorted {
                let lhsArea = $0.tileWidth * $0.tileHeight
                let rhsArea = $1.tileWidth * $1.tileHeight
                return lhsArea > rhsArea
            }
            .first
    }
    
    func buildVODCues(track: DASHThumbnailTrack,
                      totalDuration: TimeInterval) -> [DASHThumbnailCue] {
        guard totalDuration > 0 else { return [] }
        
        let tileCount = max(1, track.columns * track.rows)
        let thumbnailDuration = track.duration / Double(tileCount)
        
        guard thumbnailDuration > 0 else { return [] }
        
        let spriteCount = max(1, Int(ceil(totalDuration / track.duration)))
        return buildCues(
            track: track,
            spriteStartIndex: 0,
            spriteCount: spriteCount,
            thumbnailDuration: thumbnailDuration,
            totalDuration: totalDuration
        )
    }
    
    func buildLiveCues(manifest: DASHManifest,
                       track: DASHThumbnailTrack,
                       now: Date) -> [DASHThumbnailCue] {
        guard let availabilityStartTime = manifest.availabilityStartTime else {
            return []
        }
        
        let tileCount = max(1, track.columns * track.rows)
        let spriteDuration = track.duration
        guard spriteDuration > 0 else { return [] }
        
        let thumbnailDuration = spriteDuration / Double(tileCount)
        guard thumbnailDuration > 0 else { return [] }
        
        let liveEdgeSeconds = now.timeIntervalSince(availabilityStartTime)
        guard liveEdgeSeconds > 0 else { return [] }
        
        let liveEdgeSpriteIndex = Int(floor(liveEdgeSeconds / spriteDuration))
        let lastPublishedSpriteIndex = liveEdgeSpriteIndex - liveSafetyDelaySprites
        
        guard lastPublishedSpriteIndex >= 0 else {
            return []
        }
        
        let firstPublishedSpriteIndex = max(
            0,
            lastPublishedSpriteIndex - liveWindowSpriteCount + 1
        )
        
        let spriteCount = lastPublishedSpriteIndex - firstPublishedSpriteIndex + 1
        
        let liveWindowDuration = manifest.timeShiftBufferDepth ?? Double(liveWindowSpriteCount) * spriteDuration
        let liveWindowStart = max(0, liveEdgeSeconds - liveWindowDuration)
        
        return buildCues(
            track: track,
            spriteStartIndex: firstPublishedSpriteIndex,
            spriteCount: spriteCount,
            thumbnailDuration: thumbnailDuration,
            totalDuration: liveEdgeSeconds
        )
        .filter { $0.timeRange.upperBound >= liveWindowStart }
    }
    
    func buildCues(track: DASHThumbnailTrack,
                   spriteStartIndex: Int,
                   spriteCount: Int,
                   thumbnailDuration: TimeInterval,
                   totalDuration: TimeInterval) -> [DASHThumbnailCue] {
        guard spriteCount > 0 else { return [] }
        
        let tileCount = max(1, track.columns * track.rows)
        var cues: [DASHThumbnailCue] = []
        
        for relativeSpriteIndex in 0..<spriteCount {
            let spriteIndex = spriteStartIndex + relativeSpriteIndex
            let spriteNumber = track.startNumber + spriteIndex
            let spriteStartTime = Double(spriteIndex) * track.duration
            
            guard let imageURL = buildSpriteURL(track: track, number: spriteNumber) else {
                continue
            }
            
            for tileIndex in 0..<tileCount {
                let start = spriteStartTime + Double(tileIndex) * thumbnailDuration
                let end = min(start + thumbnailDuration, totalDuration)
                
                guard start < totalDuration, end > start else {
                    continue
                }
                
                let column = tileIndex % track.columns
                let row = tileIndex / track.columns
                
                let rect = CGRect(
                    x: column * track.tileWidth,
                    y: row * track.tileHeight,
                    width: track.tileWidth,
                    height: track.tileHeight
                )
                
                cues.append(
                    DASHThumbnailCue(
                        imageURL: imageURL,
                        sourceRect: rect,
                        timeRange: start..<end,
                        thumbnailSize: CGSize(
                            width: track.tileWidth,
                            height: track.tileHeight
                        )
                    )
                )
            }
        }
        
        return cues
    }
    
    func spriteURLs(from cues: [DASHThumbnailCue]) -> [URL] {
        return Array(Set(cues.map { $0.imageURL }))
            .sorted { $0.absoluteString < $1.absoluteString }
    }
    
    func buildSpriteURL(track: DASHThumbnailTrack, number: Int) -> URL? {
        var media = track.mediaTemplate
        media = media.replacingOccurrences(of: "$RepresentationID$", with: track.id)
        media = media.replacingOccurrences(of: "$Number$", with: "\(number)")
        media = media.replacingOccurrences(of: "$Bandwidth$", with: "\(track.bandwidth)")
        
        guard let baseURL = track.baseURL else {
            return URL(string: media)
        }
        
        return URL(string: media, relativeTo: baseURL)?.absoluteURL
    }
    
    func download(url: URL) async throws -> Data {
        if let cached = UPlayerThumbnailCache.shared.spriteData(for: url) {
            return cached
        }
        
        let request = URLRequest(
            url: url,
            cachePolicy: .returnCacheDataElseLoad,
            timeoutInterval: 20
        )
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let http = response as? HTTPURLResponse else {
            throw UPlayerErrorsList.invalidHTTPResponse
        }
        
        guard (200...299).contains(http.statusCode) else {
            throw makeError(
                errorCode: http.statusCode,
                errorMessage: HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            )
        }
        
        UPlayerThumbnailCache.shared.storeSpriteData(data, for: url)
        return data
    }
}
