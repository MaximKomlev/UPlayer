//
//  UPlayerMediaExporter.swift
//  UPlayer
//
//  Created by Max Komleu on 9/23/26.
//

//  Downloads DASH SegmentTemplate audio/video representations and exports
//  them as a single MP4. H.264/AAC are passed through. G711 is transcoded
//  to AAC using UPlayerG711ToAACTranscoder before the final mux.
//

import Photos
import Foundation
import AVFoundation

private struct SelectedRepresentation {
    let period: DASHPeriod
    let adaptation: DASHAdaptationSet
    let representation: DASHRepresentation
    let template: DASHSegmentTemplate
    let segments: [DASHSegment]
    let manifestBaseURL: URL?
}

private struct HLSByteRange {
    let length: Int64
    let offset: Int64?
}

private struct HLSResource {
    let url: URL
    let byteRange: HLSByteRange?
}

private struct HLSMediaTrack {
    let mediaType: AVMediaType
    let codec: String?
    let initialization: HLSResource
    let segments: [HLSResource]
}

private struct HLSVariant {
    let bandwidth: Int
    let codecs: String?
    let audioGroup: String?
    let playlistURL: URL
}

private struct HLSAudioRendition {
    let groupID: String
    let playlistURL: URL
}

private final class DownloadProgress {
    private let lock = NSLock()
    private let total: Int
    private var completed = 0
    private let handler: (Double) -> Void

    init(total: Int, handler: @escaping (Double) -> Void) {
        self.total = max(1, total)
        self.handler = handler
    }

    func completedOne() {
        lock.lock()
        completed += 1
        let value = min(1, Double(completed) / Double(total))
        lock.unlock()
        handler(value)
    }
}

public final class UPlayerMediaExporter {
    public typealias ProgressHandler = (_ progress: Double) -> Void
    private let session: URLSession
    private let audioTranscoder: UPlayerAudioTranscoderProtocol
    private let fileManager: FileManager
    private let lock = NSLock()
    private var cancelled = false
    private var activeTasks = [URLSessionTask]()
    private var exportSession: AVAssetExportSession?

    public var progressHandler: ProgressHandler?

    /// Headers added to initialization and media-segment requests.

    public var requestHeaders = [String: String]()

    /// Maximum video representation bandwidth. nil selects the highest bandwidth.

    public var maximumVideoBandwidth: Int?

    public init(session: URLSession = .shared,
                audioTranscoder: UPlayerAudioTranscoderProtocol = UPlayerG711ToAACTranscoder(),
                fileManager: FileManager = .default) {
        self.session = session
        self.audioTranscoder = audioTranscoder
        self.fileManager = fileManager
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        let tasks = activeTasks
        let exporter = exportSession
        lock.unlock()

        tasks.forEach { $0.cancel() }
        exporter?.cancelExport()
    }

    /// Exports MP4, native HLS, or an MPD asset that has already been
    /// normalized to HLS by the UPlayer processor pipeline.
    @discardableResult
    public func export(asset: UPlayerAssetProtocol,
                       to outputURL: URL) async throws -> URL {
        resetCancellation()
        reportProgress(0)

        switch asset.type {
        case .mp4:
            guard let sourceURL = asset.httpMetadata?.url else {
                throw UPlayerError.invalidAssetURL
            }
            try await downloadMP4(from: sourceURL, to: outputURL)
            reportProgress(1)
            return outputURL

        case .hls:
            guard let sourceURL = asset.httpMetadata?.url else {
                throw UPlayerError.invalidAssetURL
            }
            try await exportHLS(asset: asset, masterURL: sourceURL, outputURL: outputURL)
            reportProgress(1)
            return outputURL

        case .mpd:
            guard let hls = asset.hlsMetadata, !hls.master.isEmpty else {
                throw UPlayerError.assetLoadingFailed
            }
            // The MPD processors already generated HLS. Use the original MPD
            // URL only as a base URL for resolving relative playlist entries.
            try await exportHLS(asset: asset, masterURL: asset.url, outputURL: outputURL)
            reportProgress(1)
            return outputURL

        case .unknown:
            throw UPlayerError.invalidAsset
        }
    }
}

public extension UPlayerMediaExporter {
    func exportToPhotoLibrary(asset: UPlayerAssetProtocol) async throws {
        let directory = FileManager.default.temporaryDirectory
        let outputURL = directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")

        defer {
            try? FileManager.default.removeItem(at: outputURL)
        }

        let fileURL = try await export(asset: asset, to: outputURL)

        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw UPlayerError.photoLibraryAccessDenied
        }

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
        }
    }
}

// MARK: - Representation selection

private extension UPlayerMediaExporter {
    func selectRepresentation(type: DASHMediaType,
                              manifest: DASHManifest) throws -> SelectedRepresentation {
        let candidates = manifest.periods.flatMap { period in
            period.adaptationSets
                .filter { $0.type == type }
                .flatMap { adaptation in
                    adaptation.representations.compactMap { representation -> SelectedRepresentation? in
                        guard let template = representation.segmentTemplate ?? adaptation.segmentTemplate else {
                            return nil
                        }

                        let segments = makeSegments(manifest: manifest,
                                                   period: period,
                                                   template: template)

                        guard !segments.isEmpty else {
                            return nil
                        }

                        return SelectedRepresentation(period: period,
                                                      adaptation: adaptation,
                                                      representation: representation,
                                                      template: template,
                                                      segments: segments,
                                                      manifestBaseURL: manifest.baseURL)

                    }
                }
        }

        var filtered = candidates
        if type == .video, let maximumVideoBandwidth {
            let withinLimit = candidates.filter { $0.representation.bandwidth <= maximumVideoBandwidth }
            if !withinLimit.isEmpty {
                filtered = withinLimit
            }
        }

        guard let selected = filtered.max(by: { $0.representation.bandwidth < $1.representation.bandwidth }) else {
            if type == .video {
                throw UPlayerError.missingVideoRepresentation
            }
            throw UPlayerError.missingSegmentTemplate
        }
        return selected
    }

    func makeSegments(manifest: DASHManifest,
                      period: DASHPeriod,
                      template: DASHSegmentTemplate) -> [DASHSegment] {
        if let timeline = template.timeline, !timeline.isEmpty {
            return timeline.map {
                DASHSegment(number: $0.number,
                            time: $0.pts,
                            duration: $0.duration)
            }
        }

        if manifest.type == .dynamicLive {
            return expandLiveSegments(manifest: manifest,
                                      period: period,
                                      template: template)
        }

        let totalDuration = period.duration ?? manifest.mediaPresentationDuration ?? 0
        return expandVODSegments(template: template,
                                 totalDuration: totalDuration)
    }

    func expandVODSegments(template: DASHSegmentTemplate,
                           totalDuration: TimeInterval) -> [DASHSegment] {
        guard let durationTicks = template.duration,
              durationTicks > 0,
              totalDuration > 0 else {
            return []
        }

        let timescale = max(1, template.timescale)

        let segmentDuration = Double(durationTicks) / Double(timescale)
        guard segmentDuration > 0 else {
            return []
        }

        let fullCount = Int(totalDuration / segmentDuration)
        let remainder = totalDuration - Double(fullCount) * segmentDuration
        let hasPartial = remainder > 0.000_001

        let count = fullCount + (hasPartial ? 1 : 0)
        return (0..<count).map { index in
            let duration: Int64
            if index == count - 1, hasPartial {
                duration = Int64((remainder * Double(timescale)).rounded())
            } else {
                duration = Int64(durationTicks)
            }

            return DASHSegment(number: template.startNumber + index,
                               time: Int64(index * durationTicks),
                               duration: duration)
        }
    }

    /// Mirrors the live-window calculation currently used by UPlayerHLSGenerator.

    func expandLiveSegments(manifest: DASHManifest,
                            period: DASHPeriod,
                            template: DASHSegmentTemplate,
                            now: Date = Date()) -> [DASHSegment] {
        guard let availabilityStartTime = manifest.availabilityStartTime,
              let durationTicks = template.duration,
              durationTicks > 0 else {
            return []
        }

        let timescale = max(1, template.timescale)
        let segmentDuration = Double(durationTicks) / Double(timescale)
        let liveEdge = now.timeIntervalSince(availabilityStartTime) - period.start

        guard segmentDuration > 0, liveEdge > 0 else {
            return []
        }

        let liveEdgeIndex = Int(floor(liveEdge / segmentDuration))
        let safetyDelaySegments = max(6, Int(ceil((manifest.minimumUpdatePeriod ?? 2) / segmentDuration)) + 3)
        let lastPublishedIndex = liveEdgeIndex - safetyDelaySegments
        guard lastPublishedIndex >= 0 else {
            return []
        }

        let windowCount = 18
        let firstPublishedIndex = max(0, lastPublishedIndex - windowCount + 1)
        return (firstPublishedIndex...lastPublishedIndex).map { index in
            DASHSegment(number: template.startNumber + index,
                        time: Int64(index * durationTicks),
                        duration: Int64(durationTicks))
        }
    }
}

// MARK: - Download / transcode

private extension UPlayerMediaExporter {
    func makeLocalTrack(selected: SelectedRepresentation,
                        mediaType: AVMediaType,
                        directory: URL,
                        progress: DownloadProgress) async throws -> URL {
        try checkCancellation()
        let initializationURL = try buildInitializationURL(selected)
        let initializationData = try await download(initializationURL)
        progress.completedOne()

        guard !initializationData.isEmpty else {
            throw UPlayerError.emptyDownload
        }

        let outputURL = directory.appendingPathComponent(mediaType == .video ? "video.mp4" : "audio.mp4")
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }

        fileManager.createFile(atPath: outputURL.path, contents: nil)

        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }

        let needsTranscoding = mediaType == .audio && shouldTranscodeAudio(selected.representation.codecs)
        if needsTranscoding {
            guard let transcodedInitialization = try await audioTranscoder.makeInitializationSegment(originalCodec: selected.representation.codecs) else {
                throw UPlayerError.emptyDownload
            }
            try handle.write(contentsOf: transcodedInitialization.data)
        } else {
            try handle.write(contentsOf: initializationData)
        }

        // Keep segment ordering deterministic. Downloads can be parallelized later,
        // but writing fragments in presentation order is important for the local fMP4.
        for segment in selected.segments {
            try checkCancellation()
            let segmentURL = try buildSegmentURL(selected, segment: segment)
            let data = try await download(segmentURL)
            guard !data.isEmpty else {
                throw UPlayerError.emptyDownload
            }

            if needsTranscoding {
                let transcoded = try await audioTranscoder.transcodeAudioSegment(data: data,
                                                                                 initializationData: initializationData,
                                                                                 originalCodec: selected.representation.codecs,
                                                                                 sourceURL: segmentURL)
                try handle.write(contentsOf: transcoded.data)
            } else {
                try handle.write(contentsOf: data)
            }

            progress.completedOne()
        }

        try handle.synchronize()
        return outputURL
    }

    func download(_ url: URL) async throws -> Data {
        try await download(url, byteRange: nil)
    }


    // URLSessionTask is not exposed by URLResponse. Removal is also done lazily
    // before every append/cancel, so stale completed tasks are harmless.

    func removeTask(withIdentifier identifier: Int?) {
        guard let identifier else {
            return
        }

        lock.lock()
        activeTasks.removeAll { $0.taskIdentifier == identifier }
        lock.unlock()
    }

    func addTask(_ task: URLSessionTask) {
        lock.lock()
        activeTasks.removeAll { $0.state == .completed || $0.state == .canceling }
        activeTasks.append(task)
        lock.unlock()
    }

    func responseTaskIdentifier(response: URLResponse?, fallback: Int?) -> Int? {
        // Kept as a helper so download bookkeeping can be replaced by a custom
        // URLSession delegate without changing the exporter API.
        fallback
    }
}

// MARK: - HLS / MP4 download

private extension UPlayerMediaExporter {

    func downloadMP4(from sourceURL: URL, to outputURL: URL) async throws {
        try checkCancellation()
        let data = try await download(sourceURL)
        guard !data.isEmpty else { throw UPlayerError.emptyDownload }
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }
        try data.write(to: outputURL, options: .atomic)
    }

    func exportHLS(asset: UPlayerAssetProtocol,
                   masterURL: URL,
                   outputURL: URL) async throws {
        let master = try await loadPlaylist(asset: asset, url: masterURL, isMaster: true)
        let variants = try parseMasterVariants(master, baseURL: masterURL)
        guard !variants.isEmpty else {
            // A media playlist may be supplied directly instead of a master.
            let video = try parseMediaTrack(master,
                                            mediaType: .video,
                                            codec: nil,
                                            baseURL: masterURL)
            try await exportHLSLocalTracks(video: video,
                                           audio: nil,
                                           outputURL: outputURL)
            return
        }

        var candidates = variants
        if let maximumVideoBandwidth {
            let limited = variants.filter { $0.bandwidth <= maximumVideoBandwidth }
            if !limited.isEmpty { candidates = limited }
        }
        guard let variant = candidates.max(by: { $0.bandwidth < $1.bandwidth }) else {
            throw UPlayerError.missingVideoRepresentation
        }

        let videoPlaylist = try await loadPlaylist(asset: asset,
                                                   url: variant.playlistURL,
                                                   isMaster: false)
        let videoCodec = variant.codecs?.split(separator: ",")
            .map(String.init)
            .first(where: { !$0.lowercased().contains("mp4a") && !shouldTranscodeAudio($0) })
        let video = try parseMediaTrack(videoPlaylist,
                                        mediaType: .video,
                                        codec: videoCodec,
                                        baseURL: variant.playlistURL)

        var audio: HLSMediaTrack?
        if let group = variant.audioGroup,
           let rendition = try parseAudioRenditions(master, baseURL: masterURL)
                .first(where: { $0.groupID == group }) {
            let audioPlaylist = try await loadPlaylist(asset: asset,
                                                       url: rendition.playlistURL,
                                                       isMaster: false)
            let audioCodec = variant.codecs?.split(separator: ",")
                .map(String.init)
                .first(where: { $0.lowercased().contains("mp4a") || shouldTranscodeAudio($0) })
            audio = try parseMediaTrack(audioPlaylist,
                                        mediaType: .audio,
                                        codec: audioCodec,
                                        baseURL: rendition.playlistURL)
        }

        try await exportHLSLocalTracks(video: video, audio: audio, outputURL: outputURL)
    }

    func exportHLSLocalTracks(video: HLSMediaTrack,
                              audio: HLSMediaTrack?,
                              outputURL: URL) async throws {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("UPlayerExport-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let total = video.segments.count + 1 + (audio.map { $0.segments.count + 1 } ?? 0)
        let progress = DownloadProgress(total: total) { [weak self] value in
            self?.reportProgress(value * 0.85)
        }

        async let videoURL = makeLocalTrack(track: video, directory: directory, progress: progress)
        async let audioURL: URL? = {
            guard let audio else { return nil }
            return try await self.makeLocalTrack(track: audio, directory: directory, progress: progress)
        }()

        let localVideo = try await videoURL
        let localAudio = try await audioURL
        try checkCancellation()
        reportProgress(0.88)
        try await mux(videoURL: localVideo, audioURL: localAudio, outputURL: outputURL)
    }

    func makeLocalTrack(track: HLSMediaTrack,
                        directory: URL,
                        progress: DownloadProgress) async throws -> URL {
        let originalInitialization = try await download(track.initialization)
        progress.completedOne()
        guard !originalInitialization.isEmpty else { throw UPlayerError.emptyDownload }

        let outputURL = directory.appendingPathComponent(track.mediaType == .video ? "video.mp4" : "audio.mp4")
        if fileManager.fileExists(atPath: outputURL.path) { try fileManager.removeItem(at: outputURL) }
        fileManager.createFile(atPath: outputURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }

        let transcode = track.mediaType == .audio && shouldTranscodeAudio(track.codec)
        if transcode {
            guard let initSegment = try await audioTranscoder.makeInitializationSegment(originalCodec: track.codec) else {
                throw UPlayerError.emptyDownload
            }
            try handle.write(contentsOf: initSegment.data)
        } else {
            try handle.write(contentsOf: originalInitialization)
        }

        for resource in track.segments {
            try checkCancellation()
            let data = try await download(resource)
            guard !data.isEmpty else { throw UPlayerError.emptyDownload }
            if transcode {
                let sourceURL = sourceHTTPSURL(resource.url)
                let converted = try await audioTranscoder.transcodeAudioSegment(
                    data: data,
                    initializationData: originalInitialization,
                    originalCodec: track.codec,
                    sourceURL: sourceURL
                )
                try handle.write(contentsOf: converted.data)
            } else {
                try handle.write(contentsOf: data)
            }
            progress.completedOne()
        }
        try handle.synchronize()
        return outputURL
    }

    func loadPlaylist(asset: UPlayerAssetProtocol,
                      url: URL,
                      isMaster: Bool) async throws -> String {
        if let hls = asset.hlsMetadata {
            if isMaster { return hls.master }
            let filename = url.lastPathComponent
            if let playlist = hls.mediaPlaylists[filename] { return playlist }
            let stem = url.deletingPathExtension().lastPathComponent
            if let playlist = hls.mediaPlaylists["\(stem).m3u8"] { return playlist }
        }
        let data = try await download(sourceHTTPSURL(url))
        guard let string = String(data: data, encoding: .utf8) else { throw UPlayerError.assetLoadingFailed }
        return string
    }

    func parseMasterVariants(_ playlist: String, baseURL: URL) throws -> [HLSVariant] {
        let lines = playlist.components(separatedBy: .newlines)
        var result: [HLSVariant] = []
        var index = 0
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let attrs = parseAttributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
                var next = index + 1
                while next < lines.count && lines[next].trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#") { next += 1 }
                if next < lines.count {
                    let value = lines[next].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty, let url = resolveHLSURL(value, baseURL: baseURL) {
                        result.append(HLSVariant(bandwidth: Int(attrs["BANDWIDTH"] ?? "0") ?? 0,
                                                 codecs: attrs["CODECS"],
                                                 audioGroup: attrs["AUDIO"],
                                                 playlistURL: url))
                    }
                }
            }
            index += 1
        }
        return result
    }

    func parseAudioRenditions(_ playlist: String, baseURL: URL) throws -> [HLSAudioRendition] {
        playlist.components(separatedBy: .newlines).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("#EXT-X-MEDIA:") else { return nil }
            let attrs = parseAttributes(String(line.dropFirst("#EXT-X-MEDIA:".count)))
            guard attrs["TYPE"]?.uppercased() == "AUDIO",
                  let group = attrs["GROUP-ID"],
                  let uri = attrs["URI"],
                  let url = resolveHLSURL(uri, baseURL: baseURL) else { return nil }
            return HLSAudioRendition(groupID: group, playlistURL: url)
        }
    }

    func parseMediaTrack(_ playlist: String,
                         mediaType: AVMediaType,
                         codec: String?,
                         baseURL: URL) throws -> HLSMediaTrack {
        let lines = playlist.components(separatedBy: .newlines)
        var initialization: HLSResource?
        var segments: [HLSResource] = []
        var pendingRange: HLSByteRange?
        var previousEnd: Int64?

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXT-X-MAP:") {
                let attrs = parseAttributes(String(line.dropFirst("#EXT-X-MAP:".count)))
                guard let uri = attrs["URI"], let url = resolveHLSURL(uri, baseURL: baseURL) else {
                    throw UPlayerError.missingInitializationURL
                }
                initialization = HLSResource(url: url, byteRange: parseByteRange(attrs["BYTERANGE"], previousEnd: nil))
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                let value = String(line.dropFirst("#EXT-X-BYTERANGE:".count))
                pendingRange = parseByteRange(value, previousEnd: previousEnd)
            } else if !line.isEmpty && !line.hasPrefix("#") {
                guard let url = resolveHLSURL(line, baseURL: baseURL) else { throw UPlayerError.invalidSegmentURL }
                segments.append(HLSResource(url: url, byteRange: pendingRange))
                if let range = pendingRange {
                    let offset = range.offset ?? previousEnd ?? 0
                    previousEnd = offset + range.length
                }
                pendingRange = nil
            }
        }

        guard let initialization else {
            // This downloader intentionally keeps the known-good fragmented MP4 path.
            // MPEG-TS HLS requires demux/remux rather than byte concatenation.
            throw UPlayerError.unsupportedManifest
        }
        guard !segments.isEmpty else { throw UPlayerError.emptyDownload }
        // UPlayer-generated G711 playlists advertise the post-transcode AAC
        // codec in the master playlist. Preserve the original codec embedded
        // in the custom resource-loader URL so the downloader performs the
        // same G711 -> AAC conversion itself.
        let sourceCodec = transcodeSourceCodec(from: initialization.url)
        ?? segments.lazy.compactMap { [self] in
            self.transcodeSourceCodec(from: $0.url) }.first
            ?? codec
        return HLSMediaTrack(mediaType: mediaType, codec: sourceCodec, initialization: initialization, segments: segments)
    }

    func transcodeSourceCodec(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.queryItems?.contains(where: { $0.name == "mode" && $0.value?.hasPrefix("audio-transcode") == true }) == true else {
            return nil
        }
        return components.queryItems?.first(where: { $0.name == "codec" })?.value
    }

    func parseAttributes(_ value: String) -> [String: String] {
        var result: [String: String] = [:]
        var token = ""
        var quoted = false
        var parts: [String] = []
        for c in value {
            if c == "\"" { quoted.toggle(); token.append(c) }
            else if c == "," && !quoted { parts.append(token); token = "" }
            else { token.append(c) }
        }
        if !token.isEmpty { parts.append(token) }
        for part in parts {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            var v = pair[1].trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("\"") && v.hasSuffix("\"") { v.removeFirst(); v.removeLast() }
            result[pair[0].trimmingCharacters(in: .whitespaces)] = v
        }
        return result
    }

    func parseByteRange(_ value: String?, previousEnd: Int64?) -> HLSByteRange? {
        guard let value else { return nil }
        let p = value.split(separator: "@", maxSplits: 1).map(String.init)
        guard let length = Int64(p[0]) else { return nil }
        let offset = p.count > 1 ? Int64(p[1]) : previousEnd
        return HLSByteRange(length: length, offset: offset)
    }

    func resolveHLSURL(_ value: String, baseURL: URL) -> URL? {
        if let absolute = URL(string: value), absolute.scheme != nil { return absolute }
        return URL(string: value, relativeTo: baseURL)?.absoluteURL
    }

    func sourceHTTPSURL(_ url: URL) -> URL {
        guard url.scheme?.lowercased() == "uplayer", var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        c.scheme = "https"
        // mode/codec are UPlayer resource-loader instructions and must not be sent to the origin.
        c.queryItems = c.queryItems?.filter { $0.name != "mode" && $0.name != "codec" }
        if c.queryItems?.isEmpty == true { c.queryItems = nil }
        return c.url ?? url
    }

    func download(_ resource: HLSResource) async throws -> Data {
        try await download(sourceHTTPSURL(resource.url), byteRange: resource.byteRange)
    }

    func download(_ url: URL, byteRange: HLSByteRange?) async throws -> Data {
        try checkCancellation()
        var request = URLRequest(url: url)
        requestHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        if let byteRange {
            let start = byteRange.offset ?? 0
            let end = start + byteRange.length - 1
            request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        }
        return try await perform(request)
    }

    func perform(_ request: URLRequest) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            var task: URLSessionDataTask!
            task = session.dataTask(with: request) { [weak self] data, response, error in
                guard let self else { continuation.resume(throwing: UPlayerError.cancelled); return }
                self.removeTask(withIdentifier: task.taskIdentifier)
                if self.isCancelled { continuation.resume(throwing: UPlayerError.cancelled); return }
                if let error { continuation.resume(throwing: error); return }
                if let http = response as? HTTPURLResponse,
                   !(200..<300).contains(http.statusCode) && http.statusCode != 206 {
                    continuation.resume(throwing: UPlayerError.invalidHTTPResponse(http.statusCode)); return
                }
                guard let data else { continuation.resume(throwing: UPlayerError.emptyDownload); return }
                continuation.resume(returning: data)
            }
            addTask(task)
            task.resume()
        }
    }
}

// MARK: - DASH URLs

private extension UPlayerMediaExporter {
    func buildInitializationURL(_ selected: SelectedRepresentation) throws -> URL {
        guard var value = selected.template.initialization, !value.isEmpty else {
            throw UPlayerError.missingInitializationURL
        }

        value = substituteTemplate(value,
                                   representation: selected.representation,
                                   segment: nil)

        return try resolve(value,
                           selected: selected)
    }

    func buildSegmentURL(_ selected: SelectedRepresentation,
                         segment: DASHSegment) throws -> URL {

        guard var value = selected.template.media, !value.isEmpty else {
            throw UPlayerError.invalidSegmentURL
        }

        value = substituteTemplate(value,
                                   representation: selected.representation,
                                   segment: segment)

        return try resolve(value,
                           selected: selected)
    }

    func substituteTemplate(_ value: String,
                            representation: DASHRepresentation,
                            segment: DASHSegment?) -> String {

        var result = value
        result = result.replacingOccurrences(of: "$RepresentationID$", with: representation.id)
        result = result.replacingOccurrences(of: "$Bandwidth$", with: "\\(representation.bandwidth)")
        if let segment {
            result = result.replacingOccurrences(of: "$Number$", with: "\\(segment.number)")
            result = result.replacingOccurrences(of: "$Time$", with: "\\(segment.time)")
        }

        return result
    }

    func resolve(_ value: String,
                 selected: SelectedRepresentation) throws -> URL {
        if let absolute = URL(string: value), absolute.scheme != nil {
            return absolute
        }

        let base = selected.representation.baseURL
            ?? selected.adaptation.baseURL
            ?? selected.period.baseURL
            ?? selected.manifestBaseURL
        guard let base,
              let url = URL(string: value, relativeTo: base)?.absoluteURL else {
            throw UPlayerError.invalidSegmentURL
        }
        return url
    }

    func shouldTranscodeAudio(_ codec: String?) -> Bool {
        let value = codec?.lowercased() ?? ""
        return value.contains("alaw") ||
            value.contains("pcma") ||
            value.contains("g711a") ||
            value.contains("g.711a") ||
            value.contains("ulaw") ||
            value.contains("mulaw") ||
            value.contains("mu-law") ||
            value.contains("pcmu") ||
            value.contains("g711u") ||
            value.contains("g.711u")
    }
}

// MARK: - MP4 mux

private extension UPlayerMediaExporter {
    func mux(videoURL: URL,
             audioURL: URL?,
             outputURL: URL) async throws {
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = audioURL.map { AVURLAsset(url: $0) }
        let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
        guard let sourceVideoTrack = videoTracks.first else {
            throw UPlayerError.missingMediaTrack(.video)
        }

        let sourceAudioTrack: AVAssetTrack?
        if let audioAsset {
            sourceAudioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first
            if sourceAudioTrack == nil {
                throw UPlayerError.missingMediaTrack(.audio)
            }
        } else {
            sourceAudioTrack = nil
        }

        let composition = AVMutableComposition()
        guard let destinationVideoTrack = composition.addMutableTrack(withMediaType: .video,
                                                                       preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw UPlayerError.cannotCreateCompositionTrack(.video)
        }

        let videoRange = try await sourceVideoTrack.load(.timeRange)
        let videoTransform = try await sourceVideoTrack.load(.preferredTransform)
        var earliestStart = videoRange.start
        var audioRange: CMTimeRange?

        if let sourceAudioTrack {
            let range = try await sourceAudioTrack.load(.timeRange)
            audioRange = range

            if CMTimeCompare(range.start, earliestStart) < 0 {
                earliestStart = range.start
            }
        }

        let videoInsertTime = CMTimeSubtract(videoRange.start, earliestStart)
        try destinationVideoTrack.insertTimeRange(videoRange,
                                                  of: sourceVideoTrack,
                                                  at: videoInsertTime)
        destinationVideoTrack.preferredTransform = videoTransform

        if let sourceAudioTrack, let audioRange {
            guard let destinationAudioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                                           preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw UPlayerError.cannotCreateCompositionTrack(.audio)
            }

            let audioInsertTime = CMTimeSubtract(audioRange.start, earliestStart)
            try destinationAudioTrack.insertTimeRange(audioRange,
                                                      of: sourceAudioTrack,
                                                      at: audioInsertTime)
        }

        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }

        guard let exporter = AVAssetExportSession(asset: composition,
                                                  presetName: AVAssetExportPresetPassthrough) else {
            throw UPlayerError.cannotCreateExportSession
        }
        exporter.outputURL = outputURL
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true

        lock.lock()
        exportSession = exporter
        lock.unlock()

        let progressTask = Task { [weak self, weak exporter] in
            while !Task.isCancelled, let exporter {
                let p = Double(exporter.progress)
                self?.reportProgress(0.88 + p * 0.12)
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        defer {
            progressTask.cancel()
            lock.lock()
            exportSession = nil
            lock.unlock()
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exporter.exportAsynchronously {
                switch exporter.status {
                case .completed:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: UPlayerError.cancelled)
                default:
                    continuation.resume(throwing: UPlayerError.exportFailed(exporter.error))
                }
            }
        }
    }
}

// MARK: - State / progress

private extension UPlayerMediaExporter {
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func resetCancellation() {
        lock.lock()
        cancelled = false
        activeTasks.removeAll()
        exportSession = nil
        lock.unlock()
    }

    func checkCancellation() throws {
        if isCancelled || Task.isCancelled {
            throw UPlayerError.cancelled
        }
    }

    func reportProgress(_ value: Double) {
        let value = min(1, max(0, value))
        guard let progressHandler else { return }
        DispatchQueue.main.async {
            progressHandler(value)
        }
    }
}
