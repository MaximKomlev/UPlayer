//
//  UPlayerHLSGenerator.swift
//  UPlayer
//
//  Created by Max Komleu on 2/23/26.
//

import Combine
import Foundation
import AVFoundation

private let logScope = "[hls generating]"

private enum AudioTranscodeMode:
    String {

    case initialization =
        "audio-transcode-init"

    case media =
        "audio-transcode"
}

public final class UPlayerHLSGenerator: UPlayerAssetProcessorProtocol {

    private let isRunningPrivate = SyncProperty(value: false)
    private var isTaskCanceled = SyncProperty<Bool>(value: false)
    private var livePlaylistStates = [String: LiveHLSPlaylistState]()
    
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

        switch asset.type {
        case .hls, .mp4:
            isRunningPrivate.set { $0 = false }
            return Just(asset).setFailureType(to: Error.self).eraseToAnyPublisher()
        case .mpd(let type):
            if type == 0 {
                break
            }
            isRunningPrivate.set { $0 = false }
            return Just(asset).setFailureType(to: Error.self).eraseToAnyPublisher()
        default:
            break
        }
        
        log("\(logScope) started, url: \(asset.url)", loggingLevel: .debug)
        return Future { [weak self] promise in
            do {
                guard let self else {
                    throw UPlayerErrorsList.nullReference
                }
                
                defer {
                    self.isRunningPrivate.set { $0 = false }
                }
                
                if self.isTaskCanceled.value {
                    throw UPlayerErrorsList.operationCanceled
                }
                
                guard let manifest = asset.mpdMetadata?.manifest else {
                    throw UPlayerErrorsList.mpdParseNullData
                }
                
                var mediaPlaylists = self.generateMediaPlaylists(manifest: manifest)
                let thumbnailPlaylists = self.generateThumbnailPlaylists(manifest: manifest)
                for (key, playlist) in thumbnailPlaylists {
                    mediaPlaylists[key] = playlist
                }
                
                var master = self.generateMaster(manifest: manifest)
                let masterThumbnail = generateThumbnailMasterLines(manifest: manifest)
                master += masterThumbnail
                
                asset.hlsMetadata = UPlayerAssetHLSData(master: master,
                                                        mediaPlaylists: mediaPlaylists)
                
                log("\(logScope) succeed, url: \(asset.url)", loggingLevel: .debug)
                promise(.success(asset))
            } catch {
                log("\(logScope) failed, \(error), url: \(asset.url)", loggingLevel: .error)
                promise(.failure(error))
            }
        }
        .eraseToAnyPublisher()
    }

    public func cancel() {
        isTaskCanceled.set { $0 = true }
    }
    
    public func makeProcessor() -> any UPlayerAssetProcessorProtocol {
        return UPlayerHLSGenerator(id: id)
    }
}

private extension UPlayerHLSGenerator {
    
    func generateMediaPlaylists(manifest: DASHManifest) -> [String: String] {
        var result: [String: String] = [:]
        
        for period in manifest.periods {
            for adaptation in period.adaptationSets {
                for representation in adaptation.representations {
                    guard let playlist = generate(manifest: manifest,
                                                  period: period,
                                                  adaptation: adaptation,
                                                  representation: representation) else {
                        continue
                    }
                    
                    log("\(logScope) playlist: \(playlist)", loggingLevel: .debug)
                    result[playlistFileName(for: representation)] = playlist
                }
            }
        }
        
        return result
    }
    
    func generate(manifest: DASHManifest,
                  period: DASHPeriod,
                  adaptation: DASHAdaptationSet,
                  representation: DASHRepresentation) -> String? {
        
        if let template = representation.segmentTemplate ?? adaptation.segmentTemplate {
            return generateSegmentTemplatePlaylist(manifest: manifest,
                                                   period: period,
                                                   adaptation: adaptation,
                                                   representation: representation,
                                                   template: template)
        }
        
        if representation.segmentBase != nil {
            return generateSegmentBaseFallbackPlaylist(manifest: manifest,
                                                       period: period,
                                                       adaptation: adaptation,
                                                       representation: representation)
        }
        
        return nil
    }
    
    func generateSegmentTemplatePlaylist(manifest: DASHManifest,
                                         period: DASHPeriod,
                                         adaptation: DASHAdaptationSet,
                                         representation: DASHRepresentation,
                                         template: DASHSegmentTemplate) -> String? {
        
        let allSegments: [DASHSegment]
        
        if let timeline = template.timeline, !timeline.isEmpty {
            allSegments = timeline.map {
                DASHSegment(number: $0.number,
                            time: $0.pts,
                            duration: $0.duration)
            }
        } else if manifest.type == .dynamicLive {
            allSegments = expandLiveDurationBasedSegments(manifest: manifest,
                                                          period: period,
                                                          template: template)
        } else {
            let totalDuration =
            period.duration ??
            manifest.mediaPresentationDuration ??
            0
            
            allSegments = expandDurationBasedSegments(template: template,
                                                      totalDurationSeconds: totalDuration)
        }
        
        guard !allSegments.isEmpty else {
            return nil
        }
        
        let needsAudioTranscoding = shouldTranscodeAudio(adaptation: adaptation,
                                                         representation: representation)
        
        let originalInitURL = buildInitURL(manifest: manifest,
                                           period: period,
                                           adaptation: adaptation,
                                           representation: representation,
                                           template: template)
        
        let initURL: String
        
        if needsAudioTranscoding {
            
            /*
             The original DASH initialization segment describes
             the G711 track and must NOT be delivered to AVPlayer.
             
             However, our new transcoder outputs AAC fMP4, so HLS
             still needs EXT-X-MAP.
             
             The ResourceLoader intercepts this URL and generates
             an AAC fMP4 initialization segment entirely in memory.
             */
            
            initURL = makeTranscodeInitURL(originalInitURL,
                                           originalCodec: representation.codecs)
        } else {
            initURL = originalInitURL
        }
        
        if manifest.type == .dynamicLive {
            return updateLivePlaylistState(manifest: manifest,
                                           period: period,
                                           adaptation: adaptation,
                                           representation: representation,
                                           template: template,
                                           dashSegments: allSegments,
                                           initURL: initURL)
        }
        
        let segments = allSegments
        
        let targetDuration = max(
            1, Int(ceil(segments.map {
                Double($0.duration) /
                Double(max(1, template.timescale))
            }
                .max() ?? 1)))
        
        var playlist = ""
        
        playlist += "#EXTM3U\n"
        playlist += "#EXT-X-VERSION:7\n"
        playlist += "#EXT-X-TARGETDURATION:\(targetDuration)\n"
        playlist += "#EXT-X-MEDIA-SEQUENCE:\(segments.first?.number ?? template.startNumber)\n"
        playlist += "#EXT-X-PLAYLIST-TYPE:VOD\n"
        
        if !initURL.isEmpty {
            playlist += "#EXT-X-MAP:URI=\"\(initURL)\"\n"
        }
        
        for segment in segments {
            let extinf = Double(segment.duration) / Double(max(1, template.timescale))
            
            playlist += "#EXTINF:\(String(format: "%.3f", extinf)),\n"
            
            playlist += buildSegmentURL(manifest: manifest,
                                        period: period,
                                        adaptation: adaptation,
                                        representation: representation,
                                        template: template,
                                        number: segment.number)
            
            playlist += "\n"
        }
        
        playlist += "#EXT-X-ENDLIST\n"
        
        return playlist
    }
    
    func generateSegmentBaseFallbackPlaylist(manifest: DASHManifest,
                                             period: DASHPeriod,
                                             adaptation: DASHAdaptationSet,
                                             representation: DASHRepresentation) -> String? {
        
        guard let mediaURL = buildRepresentationMediaURL(manifest: manifest,
                                                         period: period,
                                                         adaptation: adaptation,
                                                         representation: representation) else {
            return nil
        }
        
        let totalDuration = period.duration ?? manifest.mediaPresentationDuration ?? 0
        guard totalDuration > 0 else { return nil }
        
        let targetDuration = max(1, Int(ceil(totalDuration)))
        
        var playlist = ""
        playlist += "#EXTM3U\n"
        playlist += "#EXT-X-VERSION:7\n"
        playlist += "#EXT-X-TARGETDURATION:\(targetDuration)\n"
        playlist += "#EXT-X-MEDIA-SEQUENCE:1\n"
        playlist += "#EXT-X-PLAYLIST-TYPE:VOD\n"
        playlist += "#EXTINF:\(String(format: "%.3f", totalDuration)),\n"
        playlist += mediaURL.absoluteString + "\n"
        playlist += "#EXT-X-ENDLIST\n"
        
        return playlist
    }
    
    func generateMaster(manifest: DASHManifest) -> String {
        
        var master = "#EXTM3U\n"
        master += "#EXT-X-VERSION:7\n"
        
        let allAdaptations =
        manifest.periods.flatMap(\.adaptationSets)
        
        let audioAdaptations = allAdaptations.filter {
            $0.type == .audio ||
            $0.mimeType?.lowercased().hasPrefix("audio/") == true
        }
        
        let videoAdaptations = allAdaptations.filter {
            $0.type == .video ||
            $0.mimeType?.lowercased().hasPrefix("video/") == true
        }
        
        let audioCandidates:
        [(adaptation: DASHAdaptationSet,
          representation: DASHRepresentation)] =
        audioAdaptations.flatMap { adaptation in
            
            adaptation.representations.map {
                (
                    adaptation: adaptation,
                    representation: $0
                )
            }
        }
        
        let primaryAudio = audioCandidates
            .sorted {
                $0.representation.bandwidth >
                $1.representation.bandwidth
            }
            .first
        
        let hasVideo = !videoAdaptations.isEmpty
        let hasAudio = !audioCandidates.isEmpty
        
        // MARK: Audio-only
        
        if !hasVideo && hasAudio {
            
            for candidate in audioCandidates {
                
                let adaptation = candidate.adaptation
                let rep = candidate.representation
                
                let playlistURL = playlistURLString(manifest: manifest,
                                                    representation: rep)
                
                var streamInf =
                "#EXT-X-STREAM-INF:BANDWIDTH=\(rep.bandwidth)"
                
                if let codec = hlsAudioCodec(adaptation: adaptation,
                                             representation: rep), !codec.isEmpty {
                    
                    streamInf += ",CODECS=\"\(codec)\""
                }
                
                master += streamInf + "\n"
                master += playlistURL + "\n"
            }
            
            //log("\(logScope) master: \(master)", loggingLevel: .debug)
            
            return master
        }
        
        // MARK: External audio rendition
        
        if let primaryAudio {
            
            let audioRep =
            primaryAudio.representation
            
            let audioPlaylistURL =
            playlistURLString(
                manifest: manifest,
                representation: audioRep
            )
            
            master += """
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="eng",DEFAULT=YES,AUTOSELECT=YES,LANGUAGE="eng",URI="\(audioPlaylistURL)"
            """
            
            master += "\n"
        }
        
        // MARK: Video variants
        
        for adaptation in videoAdaptations {
            
            for rep in adaptation.representations {
                
                let playlistURL =
                playlistURLString(
                    manifest: manifest,
                    representation: rep
                )
                
                let audioBandwidth =
                primaryAudio?
                    .representation
                    .bandwidth ?? 0
                
                let totalBandwidth =
                rep.bandwidth +
                audioBandwidth
                
                var streamInf =
                "#EXT-X-STREAM-INF:BANDWIDTH=\(totalBandwidth)"
                
                if let width = rep.width,
                   let height = rep.height {
                    
                    streamInf +=
                    ",RESOLUTION=\(width)x\(height)"
                }
                
                var codecs: [String] = []
                
                if let videoCodec = rep.codecs,
                   !videoCodec.isEmpty {
                    
                    codecs.append(videoCodec)
                }
                
                if let primaryAudio,
                   let audioCodec = hlsAudioCodec(
                    adaptation: primaryAudio.adaptation,
                    representation: primaryAudio.representation
                   ),
                   !audioCodec.isEmpty {
                    
                    codecs.append(audioCodec)
                }
                
                if !codecs.isEmpty {
                    streamInf +=
                    ",CODECS=\"\(codecs.joined(separator: ","))\""
                }
                
                if primaryAudio != nil {
                    streamInf += ",AUDIO=\"audio\""
                }
                
                master += streamInf + "\n"
                master += playlistURL + "\n"
            }
        }
        
        log(
            "\(logScope) master: \(master)",
            loggingLevel: .debug
        )
        
        return master
    }
    
    func generateThumbnailMasterLines(manifest: DASHManifest) -> String {
        var result = ""
        
        for track in manifest.thumbnailTracks {
            let fileName = thumbnailPlaylistFileName(for: track)
            let uri = playlistURLString(fileName: fileName, manifest: manifest)
            
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
        
        let width = track.tileWidth
        let height = track.tileHeight
        
        var playlist = ""
        playlist += "#EXTM3U\n"
        playlist += "#EXT-X-VERSION:7\n"
        playlist += "#EXT-X-TARGETDURATION:\(targetDuration)\n"
        playlist += "#EXT-X-MEDIA-SEQUENCE:\(track.startNumber)\n"
        playlist += "#EXT-X-PLAYLIST-TYPE:VOD\n"
        playlist += "#EXT-X-IMAGES-ONLY\n"
        playlist += "#EXT-X-TILES:RESOLUTION=\(width)x\(height),LAYOUT=\"\(track.columns)x\(track.rows)\",DURATION=\(String(format: "%.3f", thumbnailDuration))\n"
        
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
    
    func expandDurationBasedSegments(template: DASHSegmentTemplate, totalDurationSeconds: TimeInterval) -> [DASHSegment] {
        guard let durationTicks = template.duration, durationTicks > 0 else { return [] }
        
        let timescale = max(1, template.timescale)
        let segSeconds = Double(durationTicks) / Double(timescale)
        guard totalDurationSeconds > 0, segSeconds > 0 else { return [] }
        
        let fullCount = Int(totalDurationSeconds / segSeconds)
        let remainder = totalDurationSeconds - Double(fullCount) * segSeconds
        let hasPartial = remainder > 0.000_001
        let totalCount = fullCount + (hasPartial ? 1 : 0)
        
        var segments: [DASHSegment] = []
        var number = template.startNumber
        var pts: Int64 = 0
        
        for index in 0..<totalCount {
            let isLast = index == totalCount - 1
            let durationSeconds = (isLast && hasPartial) ? remainder : segSeconds
            let durationTicksInt = Int64((durationSeconds * Double(timescale)).rounded())
            
            segments.append(
                DASHSegment(number: number, time: pts, duration: durationTicksInt)
            )
            
            number += 1
            pts += durationTicksInt
        }
        
        return segments
    }
    
    func expandLiveDurationBasedSegments(manifest: DASHManifest,
                                         period: DASHPeriod,
                                         template: DASHSegmentTemplate,
                                         now: Date = Date()) -> [DASHSegment] {
        
        guard let availabilityStartTime = manifest.availabilityStartTime else {
            return []
        }
        guard let durationTicks = template.duration, durationTicks > 0 else {
            return []
        }
        
        let timescale = max(1, template.timescale)
        let segmentDurationSeconds = Double(durationTicks) / Double(timescale)
        guard segmentDurationSeconds > 0 else {
            return []
        }
        
        let liveEdgeSeconds = now.timeIntervalSince(availabilityStartTime) - period.start
        guard liveEdgeSeconds > 0 else {
            return []
        }
        
        let liveEdgeIndex = Int(floor(liveEdgeSeconds / segmentDurationSeconds))
        
        let safetyDelaySegments = max(
            6,
            Int(ceil((manifest.minimumUpdatePeriod ?? 2) / segmentDurationSeconds)) + 3
        )
        
        let lastPublishedIndex = liveEdgeIndex - safetyDelaySegments
        guard lastPublishedIndex >= 0 else {
            return []
        }
        
        let windowSegmentCount = 18
        let firstPublishedIndex = max(0, lastPublishedIndex - windowSegmentCount + 1)
        
        var result: [DASHSegment] = []
        result.reserveCapacity(lastPublishedIndex - firstPublishedIndex + 1)
        
        for segmentIndex in firstPublishedIndex...lastPublishedIndex {
            let number = template.startNumber + segmentIndex
            let pts = Int64(segmentIndex * durationTicks)
            
            result.append(DASHSegment(number: number,
                                      time: pts,
                                      duration: Int64(durationTicks)))
        }
        
        return result
    }
    
    func liveWindow(segments: [DASHSegment],
                    template: DASHSegmentTemplate,
                    bufferDepth: TimeInterval) -> [DASHSegment] {
        guard let last = segments.last else { return [] }
        
        let timescale = Double(template.timescale)
        let lastTimeSeconds = Double(last.time + last.duration) / timescale
        let threshold = max(0, lastTimeSeconds - bufferDepth)
        
        return segments.filter {
            Double($0.time) / timescale >= threshold
        }
    }
    
    func buildSegmentURL(manifest: DASHManifest,
                         period: DASHPeriod,
                         adaptation: DASHAdaptationSet,
                         representation: DASHRepresentation,
                         template: DASHSegmentTemplate,
                         number: Int) -> String {
        
        guard var media = template.media else {
            return ""
        }
        
        media = media.replacingOccurrences(of: "$Number$",
                                           with: "\(number)")
        
        media = media.replacingOccurrences(of: "$RepresentationID$",
                                           with: representation.id)
        
        media = media.replacingOccurrences(of: "$Bandwidth$",
                                           with: "\(representation.bandwidth)")
        
        let base =
        representation.baseURL ??
        adaptation.baseURL ??
        period.baseURL ??
        manifest.baseURL
        
        let resolved: String
        
        if let absoluteURL = URL(string: media),
           absoluteURL.scheme != nil {
            
            // Important for your MPD:
            // media=""https://media-service...?...SequenceNumber=$Number$..."
            resolved = absoluteURL.absoluteString
            
        } else if let base {
            resolved = URL(string: media, relativeTo: base)?.absoluteURL.absoluteString ?? media
        } else {
            resolved = media
        }
        
        guard shouldTranscodeAudio(adaptation: adaptation,
                                   representation: representation) else {
            return resolved
        }
        
        return makeTranscodeURL(resolved, originalCodec: representation.codecs)
    }
    
    func buildInitURL(manifest: DASHManifest,
                      period: DASHPeriod,
                      adaptation: DASHAdaptationSet,
                      representation: DASHRepresentation,
                      template: DASHSegmentTemplate) -> String {
        
        guard var initialization = template.initialization else {
            return ""
        }
        
        initialization = initialization.replacingOccurrences(of: "$RepresentationID$",
                                                             with: representation.id)
        
        initialization = initialization.replacingOccurrences(of: "$Bandwidth$",
                                                             with: "\(representation.bandwidth)")
        
        if let absoluteURL = URL(string: initialization),
           absoluteURL.scheme != nil {
            
            return absoluteURL.absoluteString
        }
        
        let base =
        representation.baseURL ??
        adaptation.baseURL ??
        period.baseURL ??
        manifest.baseURL
        
        guard let base else {
            return initialization
        }
        
        return URL(string: initialization, relativeTo: base)?
            .absoluteURL
            .absoluteString
        ?? initialization
    }
    
    func buildRepresentationMediaURL(manifest: DASHManifest,
                                     period: DASHPeriod,
                                     adaptation: DASHAdaptationSet,
                                     representation: DASHRepresentation) -> URL? {
        representation.baseURL ?? adaptation.baseURL ?? period.baseURL ?? manifest.baseURL
    }
    
    func playlistFileName(for representation: DASHRepresentation) -> String {
        
        let safeID = representation.id
            .replacingOccurrences(
                of: "[^a-zA-Z0-9_-]",
                with: "_",
                options: .regularExpression
            )
        
        return "\(safeID)_\(representation.bandwidth).m3u8"
    }
    
    func playlistURLString(manifest: DASHManifest, representation: DASHRepresentation) -> String {
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
    
    func playlistURLString(fileName: String, manifest: DASHManifest) -> String {
        guard
            let baseURL = manifest.baseURL,
            var url = modifyURLScheme(baseURL)?.deletingLastPathComponent()
        else {
            return fileName
        }
        
        url.appendPathComponent(fileName)
        return url.absoluteString
    }
    
    func mergeLiveSegments(old: [LiveHLSSegment],
                           new: [LiveHLSSegment],
                           overlapCount: Int,
                           maxSegmentCount: Int) -> [LiveHLSSegment] {
        
        var mergedByNumber: [Int: LiveHLSSegment] = [:]
        
        for segment in old {
            mergedByNumber[segment.number] = segment
        }
        
        for segment in new {
            mergedByNumber[segment.number] = segment
        }
        
        let sorted = mergedByNumber.values.sorted { $0.number < $1.number }
        
        guard !sorted.isEmpty else {
            return []
        }
        
        // Keep the newest maxSegmentCount, but preserve some overlap
        let effectiveCount = maxSegmentCount
        let startIndex = max(0, sorted.count - effectiveCount)
        
        return Array(sorted[startIndex...])
    }
    
    func desiredSegmentCount(bufferDepth: TimeInterval,
                             segmentDuration: Double,
                             overlapCount: Int) -> Int {
        let liveWindowCount = max(1, Int(ceil(bufferDepth / segmentDuration)))
        return liveWindowCount + overlapCount
    }
    
    func makeLiveHLSSegments(dashSegments: [DASHSegment],
                             template: DASHSegmentTemplate,
                             manifest: DASHManifest,
                             period: DASHPeriod,
                             adaptation: DASHAdaptationSet,
                             representation: DASHRepresentation) -> [LiveHLSSegment] {
        dashSegments.map { segment in
            let duration = Double(segment.duration) / Double(template.timescale)
            let url = buildSegmentURL(manifest: manifest,
                                      period: period,
                                      adaptation: adaptation,
                                      representation: representation,
                                      template: template,
                                      number: segment.number)
            
            return LiveHLSSegment(number: segment.number,
                                  duration: duration,
                                  url: url)
        }
    }
    
    func renderLivePlaylist(initURL: String,
                            targetDuration: Int,
                            segments: [LiveHLSSegment]) -> String {
        guard !segments.isEmpty else {
            return ""
        }
        
        var playlist = ""
        playlist += "#EXTM3U\n"
        playlist += "#EXT-X-VERSION:7\n"
        playlist += "#EXT-X-TARGETDURATION:\(targetDuration)\n"
        playlist += "#EXT-X-MEDIA-SEQUENCE:\(segments.first!.number)\n"
        
        if !initURL.isEmpty {
            playlist += "#EXT-X-MAP:URI=\"\(initURL)\"\n"
        }
        
        for segment in segments {
            playlist += "#EXTINF:\(String(format: "%.3f", segment.duration)),\n"
            playlist += "\(segment.url)\n"
        }
        
        return playlist
    }
    
    func updateLivePlaylistState(manifest: DASHManifest,
                                 period: DASHPeriod,
                                 adaptation: DASHAdaptationSet,
                                 representation: DASHRepresentation,
                                 template: DASHSegmentTemplate,
                                 dashSegments: [DASHSegment],
                                 initURL: String) -> String? {
        
        let playlistKey = playlistFileName(for: representation)
        
        let freshSegments = makeLiveHLSSegments(dashSegments: dashSegments,
                                                template: template,
                                                manifest: manifest,
                                                period: period,
                                                adaptation: adaptation,
                                                representation: representation)
        
        guard !freshSegments.isEmpty else {
            return nil
        }
        
        let segmentDuration = freshSegments.last?.duration ?? 2
        let overlapCount = 3
        let maxCount = desiredSegmentCount(bufferDepth: manifest.timeShiftBufferDepth ?? 30,
                                           segmentDuration: segmentDuration,
                                           overlapCount: overlapCount)
        
        let previousSegments = livePlaylistStates[playlistKey]?.segments ?? []
        
        let mergedSegments = mergeLiveSegments(old: previousSegments,
                                               new: freshSegments,
                                               overlapCount: overlapCount,
                                               maxSegmentCount: maxCount)
        
        let targetDuration = max(
            1,
            Int(ceil(mergedSegments.map(\.duration).max() ?? segmentDuration))
        )
        
        let state = LiveHLSPlaylistState(key: playlistKey,
                                         initURL: initURL,
                                         targetDuration: targetDuration,
                                         segments: mergedSegments)
        
        livePlaylistStates[playlistKey] = state
        
        return renderLivePlaylist(initURL: state.initURL,
                                  targetDuration: state.targetDuration,
                                  segments: state.segments)
    }
    
    func normalizeAudioCodec(_ codec: String?) -> String? {
        
        guard let codec = codec?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !codec.isEmpty else {
            return nil
        }
        
        let parts = codec.split(separator: ".")
        
        if parts.count == 3,
           parts[0] == "mp4a",
           parts[1] == "40",
           let objectType = Int(parts[2]) {
            
            return "mp4a.40.\(objectType)"
        }
        
        return codec
    }
    
    func isAudioRepresentation(adaptation: DASHAdaptationSet,
                               representation: DASHRepresentation) -> Bool {
        
        // Primary source.
        if adaptation.type == .audio {
            return true
        }
        
        // MPD in this question hits this path.
        if adaptation.mimeType?.lowercased().hasPrefix("audio/") == true {
            return true
        }
        
        if representation.mimeType?.lowercased().hasPrefix("audio/") == true {
            return true
        }
        
        guard let codec = normalizeAudioCodec(representation.codecs) else {
            return false
        }
        
        switch codec {
        case "alaw",
            "ulaw",
            "pcma",
            "pcmu",
            "g711",
            "g711a",
            "g711u":
            
            return true
            
        default:
            return codec.hasPrefix("mp4a.") ||
            codec.contains("g711") ||
            codec.contains("g.711")
        }
    }
    
    func isAudioAcceptedByAVPlayer(adaptation: DASHAdaptationSet,
                                   representation: DASHRepresentation) -> Bool {
        
        guard isAudioRepresentation(adaptation: adaptation,
                                    representation: representation) else {
            return true
        }
        
        guard let codec = normalizeAudioCodec(representation.codecs) else {
            return false
        }
        
        switch codec {
            
        case "mp4a.40.2",    // AAC-LC
            "mp4a.40.5",    // HE-AAC
            "mp4a.40.29":   // HE-AAC v2
            
            return true
            
        default:
            return false
        }
    }
    
    func shouldTranscodeAudio(adaptation: DASHAdaptationSet,
                              representation: DASHRepresentation) -> Bool {
        
        guard isAudioRepresentation(adaptation: adaptation,
                                    representation: representation) else {
            return false
        }
        
        return !isAudioAcceptedByAVPlayer(adaptation: adaptation,
                                          representation: representation)
    }
    
    func hlsAudioCodec(adaptation: DASHAdaptationSet,
                       representation: DASHRepresentation) -> String? {
        
        if shouldTranscodeAudio(adaptation: adaptation,
                                representation: representation) {
            return "mp4a.40.2"
        }
        
        return normalizeAudioCodec(representation.codecs)
    }
    
    func makeTranscodeURL(_ url: String, originalCodec: String?) -> String {
        makeAudioTranscodeURL(url, originalCodec: originalCodec, mode: .media)
    }
    
    func makeTranscodeInitURL(_ url: String, originalCodec: String?) -> String {
        makeAudioTranscodeURL(url, originalCodec: originalCodec, mode: .initialization)
    }
    
    private func makeAudioTranscodeURL(_ url: String, originalCodec: String?, mode: AudioTranscodeMode) -> String {

        guard !url.isEmpty,
              let schemeRange = url.range(of: "://") else {
            return url
        }

        var result = "uplayer://" + url[schemeRange.upperBound...]
        let separator = result.contains("?") ? "&" : "?"

        result += "\(separator)mode=\(mode.rawValue)"

        if let codec = normalizeAudioCodec(originalCodec) {
            result += "&codec=\(codec)"
        }

        return result
    }
}
