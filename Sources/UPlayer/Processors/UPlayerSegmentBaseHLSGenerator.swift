//
//  UPlayerSegmentBaseHLSGenerator.swift
//  UPlayer
//
//  Created by Max Komleu on 3/23/26.
//

import Combine
import Foundation
import AVFoundation

private let logScope = "[hls sb generating]"

public final class UPlayerSegmentBaseHLSGenerator: UPlayerAssetProcessorProtocol {

    private let isRunningPrivate = SyncProperty(value: false)
    private var isTaskCanceled = SyncProperty<Bool>(value: false)

    public let id: String

    public init(id: String) {
        self.id = id
    }

    public var isRunning: Bool {
        isRunningPrivate.value
    }

    public func process(asset: UPlayerAssetProtocol) -> AnyPublisher<UPlayerAssetProtocol, Error> {
        isTaskCanceled.set { $0 = false }
        isRunningPrivate.set { $0 = true }

        // Already resolved
        switch asset.type {
        case .hls, .mp4:
            isRunningPrivate.set { $0 = false }
            return Just(asset)
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        default:
            break
        }
        
        if asset.hlsMetadata != nil {
            isRunningPrivate.set { $0 = false }
            return Just(asset)
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }

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
                        throw UPlayerErrorsList.mpdParseNullData
                    }

                    guard manifest.containsSegmentBaseMedia() else {
                        promise(.success(asset))
                        log("\(logScope) failed, not segment base format", loggingLevel: .debug)
                        return
                    }

                    var mediaPlaylists = try await self.generateMediaPlaylists(manifest: manifest)

                    let thumbnailPlaylists = self.generateThumbnailPlaylists(manifest: manifest)
                    for (key, playlist) in thumbnailPlaylists {
                        mediaPlaylists[key] = playlist
                    }

                    guard !mediaPlaylists.isEmpty else {
                        promise(.success(asset))
                        log("\(logScope) failed, not segment base format", loggingLevel: .debug)
                        return
                    }

                    var master = self.generateMaster(manifest: manifest)
                    master += self.generateThumbnailMasterLines(manifest: manifest)
                    
                    asset.hlsMetadata = UPlayerAssetHLSData(master: master,
                                                            mediaPlaylists: mediaPlaylists)
                    asset.type = .mpd(1)

                    log("\(logScope) succeed, url: \(asset.url)", loggingLevel: .debug)
                    promise(.success(asset))
                } catch {
                    log("\(logScope) failed, \(error), url: \(asset.url)", loggingLevel: .error)
                    promise(.failure(error))
                }
            }
        }
        .eraseToAnyPublisher()
    }

    public func cancel() {
        isTaskCanceled.set { $0 = true }
    }
}

// MARK: - Generation

private extension UPlayerSegmentBaseHLSGenerator {
    
    func generateMediaPlaylists(manifest: DASHManifest) async throws -> [String: String] {
        var result: [String: String] = [:]
        
        for period in manifest.periods {
            for adaptation in period.adaptationSets where adaptation.type == .video || adaptation.type == .audio {
                for representation in adaptation.representations where representation.segmentBase != nil {
                    guard representation.segmentBase != nil else { continue }
                    
                    if isTaskCanceled.value {
                        throw UPlayerErrorsList.operationCanceled
                    }
                    
                    guard let playlist = try await generate(manifest: manifest,
                                                            period: period,
                                                            adaptation: adaptation,
                                                            representation: representation) else {
                        continue
                    }
                    
                    //log("\(logScope) playlist: \(playlist)")
                    result[playlistFileName(for: representation)] = playlist
                }
            }
        }
        
        return result
    }
    
    func generate(manifest: DASHManifest,
                  period: DASHPeriod,
                  adaptation: DASHAdaptationSet,
                  representation: DASHRepresentation) async throws -> String? {
        
        guard
            let segmentBase = representation.segmentBase,
            let initRange = segmentBase.initializationRange,
            let indexRange = segmentBase.indexRange,
            let mediaURL = buildRepresentationMediaURL(manifest: manifest,
                                                       period: period,
                                                       adaptation: adaptation,
                                                       representation: representation)
        else {
            return nil
        }
        
        let sidxData = try await RemoteByteRangeLoader.load(url: mediaURL,
                                                            range: indexRange)
        
        let sidx = try MP4SIDXParser.parse(data: sidxData)
        
        let hlsMediaURL = mediaURLForHLS(mediaURL: mediaURL,
                                         adaptation: adaptation,
                                         representation: representation)
        
        return HLSByteRangeGenerator.generatePlaylist(mediaURL: hlsMediaURL,
                                                      initRange: initRange,
                                                      sidxRange: indexRange,
                                                      sidx: sidx,
                                                      isLive: manifest.type == .dynamicLive)
    }
    
    func generateMaster(manifest: DASHManifest) -> String {
        var master = "#EXTM3U\n"
        master += "#EXT-X-VERSION:7\n"
        
        let allAdaptations = manifest.periods.flatMap(\.adaptationSets)
        let videoAdaptations = allAdaptations.filter { $0.type == .video }
        let audioAdaptations = allAdaptations.filter { $0.type == .audio }
        
        let hasVideo = !videoAdaptations.isEmpty
        let hasAudio = !audioAdaptations.isEmpty
        
        // Audio-only manifest
        if !hasVideo && hasAudio {
            for adaptation in audioAdaptations {
                for rep in adaptation.representations where rep.segmentBase != nil {
                    var streamInf = "#EXT-X-STREAM-INF:BANDWIDTH=\(rep.bandwidth)"
                    
                    if let codecs = hlsAudioCodec(adaptation: adaptation, representation: rep), !codecs.isEmpty {
                        streamInf += ",CODECS=\"\(codecs)\""
                    }
                    
                    master += streamInf + "\n"
                    master += playlistURLString(manifest: manifest, representation: rep) + "\n"
                }
            }
            
            //log("\(logScope) master: \(master)")
            return master
        }
        
        let primaryAudioRep = audioAdaptations
            .flatMap(\.representations)
            .filter { $0.segmentBase != nil }
            .sorted { $0.bandwidth > $1.bandwidth }
            .first
        
        if let audioRep = primaryAudioRep {
            let audioPlaylistURL = playlistURLString(
                manifest: manifest,
                representation: audioRep
            )
            
            master += """
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="audio",DEFAULT=YES,AUTOSELECT=YES,URI="\(audioPlaylistURL)"
            """
            master += "\n"
        }
        
        for adaptation in videoAdaptations {
            for rep in adaptation.representations where rep.segmentBase != nil {
                let totalBandwidth = rep.bandwidth + (primaryAudioRep?.bandwidth ?? 0)
                
                var streamInf = "#EXT-X-STREAM-INF:BANDWIDTH=\(totalBandwidth)"
                
                if let width = rep.width, let height = rep.height {
                    streamInf += ",RESOLUTION=\(width)x\(height)"
                }
                
                var codecsList: [String] = []
                if let videoCodecs = rep.codecs, !videoCodecs.isEmpty {
                    codecsList.append(videoCodecs)
                }
                if let audioRep = primaryAudioRep,
                   let audioCodecs = hlsAudioCodec(adaptation: adaptation, representation: audioRep),
                   !audioCodecs.isEmpty {
                    codecsList.append(audioCodecs)
                }
                if !codecsList.isEmpty {
                    streamInf += ",CODECS=\"\(codecsList.joined(separator: ","))\""
                }
                
                if primaryAudioRep != nil {
                    streamInf += ",AUDIO=\"audio\""
                }
                
                master += streamInf + "\n"
                master += playlistURLString(manifest: manifest, representation: rep) + "\n"
            }
        }
        
        return master
    }
    
    func generateThumbnailMasterLines(manifest: DASHManifest) -> String {
        var result = ""
        
        for track in manifest.thumbnailTracks {
            let uri = thumbnailPlaylistFileName(for: track)
            
            result += """
            #EXT-X-IMAGE-STREAM-INF:BANDWIDTH=\(track.bandwidth),RESOLUTION=\(track.tileWidth)x\(track.tileHeight),CODECS="jpeg",URI="\(uri)"
            
            """
        }
        
        return result
    }
    
    func generateThumbnailPlaylists(manifest: DASHManifest) -> [String: String] {
        var result: [String: String] = [:]
        
        for track in manifest.thumbnailTracks {
            result[thumbnailPlaylistFileName(for: track)] = generateThumbnailPlaylist(track: track)
        }
        
        return result
    }
    
    func generateThumbnailPlaylist(track: DASHThumbnailTrack) -> String {
        let tileCount = max(1, track.columns * track.rows)
        let thumbnailDuration = track.duration / Double(tileCount)
        let targetDuration = max(1, Int(ceil(track.duration)))
        
        var playlist = ""
        playlist += "#EXTM3U\n"
        playlist += "#EXT-X-VERSION:7\n"
        playlist += "#EXT-X-TARGETDURATION:\(targetDuration)\n"
        playlist += "#EXT-X-MEDIA-SEQUENCE:\(track.startNumber)\n"
        playlist += "#EXT-X-PLAYLIST-TYPE:VOD\n"
        playlist += "#EXT-X-IMAGES-ONLY\n"
        playlist += "#EXT-X-TILES:RESOLUTION=\(track.tileWidth)x\(track.tileHeight),LAYOUT=\"\(track.columns)x\(track.rows)\",DURATION=\(String(format: "%.3f", thumbnailDuration))\n"
        
        let url = buildThumbnailTileURL(track: track, number: track.startNumber)
        
        playlist += "#EXTINF:\(String(format: "%.3f", track.duration)),\n"
        playlist += "\(url)\n"
        playlist += "#EXT-X-ENDLIST\n"
        
        return playlist
    }
    
    func thumbnailPlaylistFileName(for track: DASHThumbnailTrack) -> String {
        "\(track.id)_images.m3u8"
    }
    
    func buildThumbnailTileURL(track: DASHThumbnailTrack, number: Int) -> String {
        var media = track.mediaTemplate
        media = media.replacingOccurrences(of: "$RepresentationID$", with: track.id)
        media = media.replacingOccurrences(of: "$Number$", with: "\(number)")
        media = media.replacingOccurrences(of: "$Bandwidth$", with: "\(track.bandwidth)")
        
        guard let baseURL = track.baseURL else {
            return media
        }
        
        return URL(string: media, relativeTo: baseURL)?.absoluteString ?? media
    }
    
    func playlistFileName(for representation: DASHRepresentation) -> String {
        "\(representation.bandwidth).m3u8"
    }
    
    func playlistURLString(manifest: DASHManifest,
                           representation: DASHRepresentation) -> String {
        let fileName = playlistFileName(for: representation)
        
        guard
            let baseURL = manifest.baseURL,
            var url = modifyURLScheme(baseURL)?.deletingLastPathComponent()
        else {
            return fileName
        }
        
        url.appendPathComponent(fileName)
        return url.absoluteString
    }
    
    func buildRepresentationMediaURL(manifest: DASHManifest,
                                     period: DASHPeriod,
                                     adaptation: DASHAdaptationSet,
                                     representation: DASHRepresentation) -> URL? {
        
        if let repURL = representation.baseURL {
            return resolve(url: repURL, againstMPD: manifest.baseURL)
        }
        
        if let adaptationURL = adaptation.baseURL {
            return resolve(url: adaptationURL, againstMPD: manifest.baseURL)
        }
        
        if let periodURL = period.baseURL {
            return resolve(url: periodURL, againstMPD: manifest.baseURL)
        }
        
        return nil
    }
    
    func resolve(url: URL, againstMPD mpdURL: URL?) -> URL {
        if url.scheme != nil {
            return url
        }
        
        guard let base = mpdURL?.deletingLastPathComponent() else {
            return url
        }
        
        return URL(string: url.relativeString, relativeTo: base)?.absoluteURL ?? url
    }
    
    func isAudioAcceptedByAVPlayer(adaptation: DASHAdaptationSet,
                                   representation: DASHRepresentation) -> Bool {
        let codec = normalizeMP4ACodec(representation.codecs)
        
        guard adaptation.type == .audio ||
                representation.mimeType?.contains("audio") == true ||
                codec?.hasPrefix("mp4a.") == true else {
            return true
        }
        
        switch codec {
        case "mp4a.40.2", "mp4a.40.5", "mp4a.40.29":
            return true
        default:
            return false
        }
    }
    
    func shouldRouteAudioThroughResourceLoader(adaptation: DASHAdaptationSet,
                                               representation: DASHRepresentation) -> Bool {
        let codec = normalizeMP4ACodec(representation.codecs)
        
        let isAudio =
        adaptation.type == .audio ||
        representation.mimeType?.contains("audio") == true ||
        codec?.hasPrefix("mp4a.") == true ||
        codec == "ec-3" ||
        codec == "ac-3" ||
        codec == "pcma" ||
        codec == "pcmu" ||
        codec?.contains("g711") == true
        
        return isAudio && !isAudioAcceptedByAVPlayer(
            adaptation: adaptation,
            representation: representation
        )
    }
    
    func hlsAudioCodec(adaptation: DASHAdaptationSet,
                       representation: DASHRepresentation) -> String? {
        if shouldRouteAudioThroughResourceLoader(
            adaptation: adaptation,
            representation: representation
        ) {
            return "mp4a.40.2"
        }

        return normalizeMP4ACodec(representation.codecs)
    }
    
    func makeUPlayerTranscodeURL(_ url: URL,
                                 originalCodec: String?) -> URL {
        guard var components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            return url
        }
        
        components.scheme = "uplayer"
        
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "mode", value: "audio-transcode"))
        
        if let originalCodec, !originalCodec.isEmpty {
            queryItems.append(URLQueryItem(name: "codec", value: originalCodec))
        }
        
        components.queryItems = queryItems
        
        return components.url ?? url
    }
    
    func mediaURLForHLS(mediaURL: URL,
                        adaptation: DASHAdaptationSet,
                        representation: DASHRepresentation) -> URL {
        guard shouldRouteAudioThroughResourceLoader(
            adaptation: adaptation,
            representation: representation
        ) else {
            return mediaURL
        }
        
        return makeUPlayerTranscodeURL(
            mediaURL,
            originalCodec: representation.codecs
        )
    }
}
