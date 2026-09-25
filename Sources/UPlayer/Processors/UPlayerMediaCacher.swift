//
//  UPlayerMediaCacher.swift
//  UPlayer
//
//  Created by Max Komleu on 9/23/26.
//

//  Prefetches generated HLS video and audio media locally and rewrites media
//  resources to uplayer:// URLs. Transcoded audio keeps its original G711 bytes
//  on disk; the resource loader consumes those bytes and transcodes to AAC on demand.
//

import Combine
import Foundation

private let mediaCacheLogScope = "[media cacher]"

private struct ByteRange {
    let length: Int64
    let offset: Int64
}

private struct Resource {
    let url: URL
    let byteRange: ByteRange?
}

internal var commonCacheDirectory: URL {
    guard let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("UPlayerMediaCache", isDirectory: true) else {
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("UPlayerMediaCache", isDirectory: true)
    }
    
    return dir
}

public final class UPlayerMediaCacher: UPlayerAssetProcessorProtocol {

    private let isRunningPrivate = SyncProperty(value: false)
    private let isTaskCanceled = SyncProperty(value: false)
    private let fileManager: FileManager
    private let session: URLSession
    private var processingTask: Task<Void, Never>?

    public let id: String

    /// Headers applied to video and audio initialization/media requests.
    public var requestHeaders = [String: String]()

    /// Cache only one video representation. When set, the highest-bandwidth
    /// representation not exceeding this value is preferred. If none is below
    /// the limit, the lowest-bandwidth representation is used. When nil, the
    /// highest-bandwidth representation is cached.
    public var maximumVideoBandwidth: Int?

    /// Maximum number of whole HLS media segments downloaded concurrently.
    /// Byte-range playlists are still cached sequentially because omitted
    /// EXT-X-BYTERANGE offsets depend on the previous range.
    public var maximumConcurrentDownloads: Int = 6

    /// Remove an asset after this much time without a cache hit. `nil` disables
    /// age-based eviction. Defaults to 24 hours.
    public var cacheExpirationInterval: TimeInterval? = 24 * 60 * 60

    /// Maximum size of UPlayerMediaCache. Least-recently-used assets are removed
    /// when this limit is exceeded. `nil` disables size-based eviction.
    public var maximumCacheSize: Int64? = 2 * 1024 * 1024 * 1024

    /// Root directory used by the cache. Each asset gets its own deterministic subdirectory.
    public let cacheDirectory: URL

    public required convenience init(id: String) {
        self.init(id: id, cacheDirectory: commonCacheDirectory)
    }

    public init(id: String,
                cacheDirectory: URL,
                session: URLSession = .shared,
                fileManager: FileManager = .default) {
        self.id = id
        self.cacheDirectory = cacheDirectory
        self.session = session
        self.fileManager = fileManager
    }

    public var isRunning: Bool {
        isRunningPrivate.value
    }

    public func process(asset: UPlayerAssetProtocol) -> AnyPublisher<UPlayerAssetProtocol, Error> {
        isTaskCanceled.set { $0 = false }
        isRunningPrivate.set { $0 = true }

        guard let hlsMetadata = asset.hlsMetadata else {
            isRunningPrivate.set { $0 = false }
            return Just(asset)
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }

        return Future { [weak self] promise in
            guard let self else {
                promise(.failure(UPlayerError.nullReference))
                return
            }

            let task = Task { [weak self] in
                guard let self else { return }

                defer {
                    self.isRunningPrivate.set { $0 = false }
                    self.processingTask = nil
                }

                do {
                    try self.checkCancellation()

                    let videoVariants = self.videoVariants(master: hlsMetadata.master,
                                                               mediaPlaylists: hlsMetadata.mediaPlaylists)

                    guard let selectedVariant = self.selectVideoVariant(videoVariants) else {
                        log("\(mediaCacheLogScope) no video playlists found, url: \(asset.url)", loggingLevel: .debug)
                        promise(.success(asset))
                        return
                    }

                    log("\(mediaCacheLogScope) selected video playlist \(selectedVariant.key), bandwidth: \(selectedVariant.bandwidth ?? -1), available video playlists: \(videoVariants.count)", loggingLevel: .debug)

                    let assetDirectory = self.cacheDirectory.appendingPathComponent(self.stableIdentifier(asset.url.absoluteString),
                                                isDirectory: true)
                    let cacheManager = UPlayerMediaCacheManager(rootDirectory: self.cacheDirectory,
                                                                fileManager: self.fileManager)

                    // Reclaim stale/LRU assets before consuming more user storage.
                    cacheManager.cleanupTemporarySegmentBaseFiles()
                    cacheManager.cleanup(expirationInterval: self.cacheExpirationInterval,
                                         maximumSize: self.maximumCacheSize,
                                         excluding: assetDirectory)

                    try self.fileManager.createDirectory(at: assetDirectory,
                                                         withIntermediateDirectories: true)
                    try cacheManager.register(assetURL: asset.url, directory: assetDirectory)

                    guard let playlist = hlsMetadata.mediaPlaylists[selectedVariant.key] else {
                        throw UPlayerError.assetLoadingFailed
                    }

                    let playlistDirectory = assetDirectory
                        .appendingPathComponent(self.stableIdentifier(selectedVariant.key), isDirectory: true)
                    try self.fileManager.createDirectory(at: playlistDirectory,
                                                         withIntermediateDirectories: true)

                    let updated = try await self.cacheVideoPlaylist(playlist,
                                                                    playlistKey: selectedVariant.key,
                                                                    directory: playlistDirectory)

                    var updatedPlaylists = hlsMetadata.mediaPlaylists
                    updatedPlaylists[selectedVariant.key] = updated

                    // Prefetch every external audio rendition referenced by the master.
                    // For G711 playlists this stores the ORIGINAL G711 fMP4 bytes;
                    // playback still performs the existing on-demand AAC transcoding.
                    let audioKeys = self.audioPlaylistKeys(master: hlsMetadata.master,
                                                           mediaPlaylists: hlsMetadata.mediaPlaylists)
                    var cachedAudioPlaylists = 0
                    for audioKey in audioKeys {
                        try self.checkCancellation()
                        guard let audioPlaylist = hlsMetadata.mediaPlaylists[audioKey] else { continue }

                        let audioDirectory = assetDirectory
                            .appendingPathComponent("audio-\(self.stableIdentifier(audioKey))", isDirectory: true)
                        try self.fileManager.createDirectory(at: audioDirectory,
                                                             withIntermediateDirectories: true)

                        updatedPlaylists[audioKey] = try await self.cacheAudioPlaylist(audioPlaylist,
                                                                                      playlistKey: audioKey,
                                                                                      directory: audioDirectory)
                        cachedAudioPlaylists += 1
                    }

                    hlsMetadata.mediaPlaylists = updatedPlaylists
                    hlsMetadata.master = self.masterKeepingOnlySelectedVideo(master: hlsMetadata.master,
                                                                              selected: selectedVariant,
                                                                              mediaPlaylists: updatedPlaylists)

                    // Refresh access metadata after a successful prefetch, then enforce
                    // the global limit again now that the incoming asset size is known.
                    try cacheManager.register(assetURL: asset.url, directory: assetDirectory)
                    cacheManager.cleanup(expirationInterval: self.cacheExpirationInterval,
                                         maximumSize: self.maximumCacheSize,
                                         excluding: assetDirectory)

                    log("\(mediaCacheLogScope) succeed, cached video playlists: 1/\(videoVariants.count), cached audio playlists: \(cachedAudioPlaylists)/\(audioKeys.count), url: \(asset.url)", loggingLevel: .debug)
                    promise(.success(asset))
                } catch {
                    log("\(mediaCacheLogScope) failed, url: \(asset.url), error: \(error)", loggingLevel: .error)
                    promise(.failure(error))
                }
            }

            self.processingTask = task
        }
        .eraseToAnyPublisher()
    }

    public func cancel() {
        isTaskCanceled.set { $0 = true }
        processingTask?.cancel()
        processingTask = nil
    }

    public func makeProcessor() -> UPlayerAssetProcessorProtocol {
        let processor = UPlayerMediaCacher(id: id,
                                           cacheDirectory: cacheDirectory,
                                           session: session,
                                           fileManager: fileManager)
        processor.requestHeaders = requestHeaders
        processor.maximumVideoBandwidth = maximumVideoBandwidth
        processor.maximumConcurrentDownloads = maximumConcurrentDownloads
        processor.cacheExpirationInterval = cacheExpirationInterval
        processor.maximumCacheSize = maximumCacheSize
        return processor
    }
}

// MARK: - Master playlist

private extension UPlayerMediaCacher {

    struct VideoVariant {
        let streamInf: String
        let uri: String
        let key: String
        let bandwidth: Int?
    }

    func videoVariants(master: String,
                       mediaPlaylists: [String: String]) -> [VideoVariant] {
        let lines = playlistLines(master)
        var result = [VideoVariant]()
        var pendingStreamInf: String?
        var pendingIsVideo = false

        for line in lines {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pendingStreamInf = line
                if let codecs = attribute(named: "CODECS", in: line)?.lowercased() {
                    pendingIsVideo = codecs.contains("avc1") ||
                        codecs.contains("avc3") ||
                        codecs.contains("hvc1") ||
                        codecs.contains("hev1") ||
                        codecs.contains("vp09") ||
                        codecs.contains("av01")
                } else {
                    pendingIsVideo = true
                }
                continue
            }

            guard let streamInf = pendingStreamInf, !line.hasPrefix("#") else { continue }
            pendingStreamInf = nil
            guard pendingIsVideo,
                  let key = playlistKey(for: line, mediaPlaylists: mediaPlaylists) else { continue }

            let bandwidth = attribute(named: "BANDWIDTH", in: streamInf).flatMap(Int.init)
            result.append(VideoVariant(streamInf: streamInf,
                                       uri: line,
                                       key: key,
                                       bandwidth: bandwidth))
        }
        return result
    }

    func selectVideoVariant(_ variants: [VideoVariant]) -> VideoVariant? {
        guard !variants.isEmpty else { return nil }

        let sorted = variants.sorted { ($0.bandwidth ?? 0) < ($1.bandwidth ?? 0) }
        guard let maximumVideoBandwidth else { return sorted.last }

        return sorted.last(where: { ($0.bandwidth ?? 0) <= maximumVideoBandwidth }) ?? sorted.first
    }

    func masterKeepingOnlySelectedVideo(master: String,
                                        selected: VideoVariant,
                                        mediaPlaylists: [String: String]) -> String {
        let lines = master.components(separatedBy: .newlines)
        var output = [String]()
        var pendingStreamInf: String?

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pendingStreamInf = rawLine
                continue
            }

            if let streamInf = pendingStreamInf, !line.hasPrefix("#"), !line.isEmpty {
                pendingStreamInf = nil
                if playlistKey(for: line, mediaPlaylists: mediaPlaylists) == selected.key {
                    output.append(streamInf)
                    output.append(rawLine)
                }
                continue
            }

            if let streamInf = pendingStreamInf {
                // Preserve unusual lines between EXT-X-STREAM-INF and its URI.
                output.append(streamInf)
                pendingStreamInf = nil
            }
            output.append(rawLine)
        }

        if let pendingStreamInf { output.append(pendingStreamInf) }
        return output.joined(separator: "\n")
    }

    func audioPlaylistKeys(master: String,
                           mediaPlaylists: [String: String]) -> [String] {
        var result = [String]()
        var seen = Set<String>()

        for line in playlistLines(master) where line.hasPrefix("#EXT-X-MEDIA:") {
            guard attribute(named: "TYPE", in: line)?.uppercased() == "AUDIO",
                  let uri = attribute(named: "URI", in: line),
                  let key = playlistKey(for: uri, mediaPlaylists: mediaPlaylists),
                  seen.insert(key).inserted else { continue }
            result.append(key)
        }
        return result
    }

    func playlistKey(for uri: String,
                     mediaPlaylists: [String: String]) -> String? {
        if mediaPlaylists[uri] != nil { return uri }
        guard let url = URL(string: uri) else { return nil }
        let filename = url.lastPathComponent
        if mediaPlaylists[filename] != nil { return filename }
        let requestedName = url.deletingPathExtension().lastPathComponent
        return mediaPlaylists.keys.first {
            URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent == requestedName
        }
    }
}

// MARK: - Media playlist caching

private extension UPlayerMediaCacher {

    func cacheAudioPlaylist(_ playlist: String,
                            playlistKey: String,
                            directory: URL) async throws -> String {
        var output = playlist.components(separatedBy: .newlines)
        var jobs = [(lineIndex: Int, sourceURL: URL, playbackURL: URL, preferredName: String, index: Int, mode: String)]()
        var segmentIndex = 0

        for lineIndex in output.indices {
            try checkCancellation()
            let line = output[lineIndex].trimmingCharacters(in: .whitespacesAndNewlines)

            if line.hasPrefix("#EXT-X-MAP:"),
               let uri = attribute(named: "URI", in: line),
               let playlistURL = URL(string: uri) {
                // audio-transcode-init is generated locally by the transcoder and
                // does not need the original G711 init bytes to produce AAC init.
                if requestMode(playlistURL) == "audio-transcode-init" { continue }
                guard let sourceURL = originalHTTPURL(from: playlistURL) else { continue }
                jobs.append((lineIndex, sourceURL, playlistURL, "init", 0, "audio-init"))
                continue
            }

            guard !line.isEmpty, !line.hasPrefix("#"), let playlistURL = URL(string: line) else { continue }
            segmentIndex += 1
            guard let sourceURL = originalHTTPURL(from: playlistURL) else { continue }
            let mode = requestMode(playlistURL) == "audio-transcode" ? "audio-transcode" : "audio-segment"
            jobs.append((lineIndex, sourceURL, playlistURL, "segment", segmentIndex, mode))
        }

        let limit = max(1, maximumConcurrentDownloads)
        var offset = 0
        while offset < jobs.count {
            try checkCancellation()
            let end = min(offset + limit, jobs.count)
            let batch = Array(jobs[offset..<end])

            let results = try await withThrowingTaskGroup(of: (Int, URL, URL, String, Bool).self) { group in
                for job in batch {
                    group.addTask { [weak self] in
                        guard let self else { throw UPlayerError.nullReference }
                        let localURL = try await self.cache(resource: Resource(url: job.sourceURL, byteRange: nil),
                                                            preferredName: job.preferredName,
                                                            index: job.index,
                                                            directory: directory)
                        let rewritten = self.audioCachedPlaybackURL(playlistURL: job.playbackURL,
                                                                    sourceURL: job.sourceURL,
                                                                    localURL: localURL,
                                                                    mode: job.mode)
                        return (job.lineIndex, rewritten, localURL, job.mode, job.preferredName == "init")
                    }
                }

                var values = [(Int, URL, URL, String, Bool)]()
                for try await value in group { values.append(value) }
                return values
            }

            for (lineIndex, playbackURL, _, _, isInitialization) in results {
                if isInitialization {
                    output[lineIndex] = "#EXT-X-MAP:URI=\"\(playbackURL.absoluteString)\""
                } else {
                    output[lineIndex] = playbackURL.absoluteString
                }
            }
            offset = end
        }

        log("\(mediaCacheLogScope) cached audio playlist \(playlistKey), segments: \(segmentIndex), prefetched resources: \(jobs.count), concurrent downloads: \(limit)", loggingLevel: .debug)
        return output.joined(separator: "\n")
    }

    func cacheVideoPlaylist(_ playlist: String,
                            playlistKey: String,
                            directory: URL) async throws -> String {
        // SegmentTemplate playlists already point at complete init/media objects.
        // Download those objects directly and concurrently.
        if !playlist.contains("#EXT-X-BYTERANGE:") &&
            !playlist.contains("BYTERANGE=") {
            return try await cacheWholeSegmentPlaylist(playlist,
                                                       playlistKey: playlistKey,
                                                       directory: directory)
        }

        // SegmentBase playlists point many byte ranges at the same MP4. Do not
        // issue one HTTP Range request per HLS segment. Download each unique
        // source object once, then extract the requested init/media ranges locally.
        return try await cacheByteRangePlaylistFromWholeResources(playlist,
                                                                  playlistKey: playlistKey,
                                                                  directory: directory)
    }

    func cacheByteRangePlaylistFromWholeResources(_ playlist: String,
                                                   playlistKey: String,
                                                   directory: URL) async throws -> String {
        struct RangeJob {
            let lineIndex: Int
            let sourceURL: URL
            let range: ByteRange
            let preferredName: String
            let index: Int
            let isInitialization: Bool
        }

        var output = playlist.components(separatedBy: .newlines)
        var jobs = [RangeJob]()
        var pendingByteRange: ByteRange?
        var previousRangeEndByURL = [String: Int64]()
        var segmentIndex = 0

        for lineIndex in output.indices {
            try checkCancellation()
            let line = output[lineIndex].trimmingCharacters(in: .whitespacesAndNewlines)

            if line.hasPrefix("#EXT-X-MAP:"),
               let uri = attribute(named: "URI", in: line),
               let sourceURL = URL(string: uri),
               let value = attribute(named: "BYTERANGE", in: line),
               let range = parseByteRange(value, previousEnd: nil),
               range.offset >= 0 {
                jobs.append(RangeJob(lineIndex: lineIndex,
                                     sourceURL: sourceURL,
                                     range: range,
                                     preferredName: "init",
                                     index: 0,
                                     isInitialization: true))
                continue
            }

            if line.hasPrefix("#EXT-X-BYTERANGE:") {
                let value = String(line.dropFirst("#EXT-X-BYTERANGE:".count))
                pendingByteRange = parseByteRange(value, previousEnd: nil)
                // The rewritten resource is a standalone local fragment, so the
                // BYTERANGE tag itself is removed from the resulting playlist.
                output[lineIndex] = ""
                continue
            }

            guard !line.isEmpty, !line.hasPrefix("#"),
                  let sourceURL = URL(string: line),
                  var range = pendingByteRange else {
                continue
            }

            if range.offset < 0 {
                guard let previousEnd = previousRangeEndByURL[sourceURL.absoluteString] else {
                    throw UPlayerError.assetLoadingFailed
                }
                range = ByteRange(length: range.length, offset: previousEnd)
            }

            segmentIndex += 1
            jobs.append(RangeJob(lineIndex: lineIndex,
                                 sourceURL: sourceURL,
                                 range: range,
                                 preferredName: "segment",
                                 index: segmentIndex,
                                 isInitialization: false))
            previousRangeEndByURL[sourceURL.absoluteString] = range.offset + range.length
            pendingByteRange = nil
        }

        // Download and process one unique SegmentBase object at a time. The complete
        // object is kept on disk instead of in Data so a large on-demand MP4 does
        // not become part of the process resident memory. This deliberately remains
        // a whole-object GET (no HTTP Range requests).
        let jobsByURL = Dictionary(grouping: jobs, by: { $0.sourceURL.absoluteString })
        let uniqueURLs = jobsByURL.values.compactMap { $0.first?.sourceURL }

        for sourceURL in uniqueURLs {
            try checkCancellation()

            let temporaryURL = try await downloadWholeResourceToTemporaryFile(sourceURL)
            defer { try? fileManager.removeItem(at: temporaryURL) }

            let handle = try FileHandle(forReadingFrom: temporaryURL)
            defer { try? handle.close() }

            let attributes = try fileManager.attributesOfItem(atPath: temporaryURL.path)
            guard let fileSizeNumber = attributes[.size] as? NSNumber else {
                throw UPlayerError.assetLoadingFailed
            }
            let fileSize = fileSizeNumber.int64Value

            guard let sourceJobs = jobsByURL[sourceURL.absoluteString] else {
                throw UPlayerError.assetLoadingFailed
            }

            for job in sourceJobs {
                try checkCancellation()

                guard job.range.offset >= 0,
                      job.range.length > 0,
                      job.range.offset <= fileSize,
                      job.range.length <= fileSize - job.range.offset,
                      job.range.length <= Int64(Int.max) else {
                    throw UPlayerError.assetLoadingFailed
                }

                try handle.seek(toOffset: UInt64(job.range.offset))
                guard let payload = try handle.read(upToCount: Int(job.range.length)),
                      payload.count == Int(job.range.length) else {
                    throw UPlayerError.assetLoadingFailed
                }

                let localURL = try store(payload: payload,
                                         sourceURL: job.sourceURL,
                                         byteRange: job.range,
                                         preferredName: job.preferredName,
                                         index: job.index,
                                         directory: directory)
                let playbackURL = cachedPlaybackURL(sourceURL: job.sourceURL,
                                                    localURL: localURL,
                                                    mode: job.isInitialization ? "video-init" : "video-segment")
                if job.isInitialization {
                    output[job.lineIndex] = "#EXT-X-MAP:URI=\"\(playbackURL.absoluteString)\""
                } else {
                    output[job.lineIndex] = playbackURL.absoluteString
                }
            }
        }

        log("\(mediaCacheLogScope) cached SegmentBase playlist \(playlistKey), segments: \(segmentIndex), whole source downloads: \(uniqueURLs.count)", loggingLevel: .debug)

        return output.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    func downloadWholeResourceToTemporaryFile(_ sourceURL: URL) async throws -> URL {
        try checkCancellation()
        var request = URLRequest(url: sourceURL,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 30)
        requestHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

        // Deliberately no Range header: SegmentBase is fetched as one complete object.
        // URLSession writes the body to disk instead of accumulating it in Data.
        let (downloadURL, response) = try await session.download(for: request)
        try checkCancellation()

        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw UPlayerError.invalidHTTPResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        let attributes = try fileManager.attributesOfItem(atPath: downloadURL.path)
        guard let sizeNumber = attributes[.size] as? NSNumber,
              sizeNumber.int64Value > 0 else {
            throw UPlayerError.emptyDownload
        }

        // Move the URLSession-owned temporary file immediately to a location we own
        // for the duration of range extraction. It is removed by the caller.
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("UPlayerSegmentBase", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory,
                                        withIntermediateDirectories: true)
        let ownedURL = temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(sourceURL.pathExtension.isEmpty ? "mp4" : sourceURL.pathExtension)

        do {
            try fileManager.moveItem(at: downloadURL, to: ownedURL)
        } catch {
            // A move can fail across volumes/filesystems. Copy is safe here because
            // it remains disk-to-disk and does not materialize the MP4 as Data.
            try fileManager.copyItem(at: downloadURL, to: ownedURL)
        }

        log("\(mediaCacheLogScope) downloaded whole resource to temporary file \(sourceURL.absoluteString), bytes: \(sizeNumber.int64Value)", loggingLevel: .debug)
        return ownedURL
    }

    func store(payload: Data,
               sourceURL: URL,
               byteRange: ByteRange?,
               preferredName: String,
               index: Int,
               directory: URL) throws -> URL {
        let ext = sourceURL.pathExtension.isEmpty ? "mp4" : sourceURL.pathExtension
        let rangeSuffix: String
        if let byteRange {
            rangeSuffix = "-\(byteRange.offset)-\(byteRange.length)"
        } else {
            rangeSuffix = ""
        }

        let filename = "\(preferredName)-\(index)-\(stableIdentifier(sourceURL.absoluteString))\(rangeSuffix).\(ext)"
        let localURL = directory.appendingPathComponent(filename)

        if fileManager.fileExists(atPath: localURL.path),
           let values = try? localURL.resourceValues(forKeys: [.fileSizeKey]),
           values.fileSize == payload.count {
            return localURL
        }

        let temporaryURL = localURL.appendingPathExtension("tmp")
        try? fileManager.removeItem(at: temporaryURL)
        try payload.write(to: temporaryURL, options: .atomic)
        try? fileManager.removeItem(at: localURL)
        try fileManager.moveItem(at: temporaryURL, to: localURL)
        return localURL
    }

    func cacheWholeSegmentPlaylist(_ playlist: String,
                                   playlistKey: String,
                                   directory: URL) async throws -> String {
        var output = playlist.components(separatedBy: .newlines)
        var jobs = [(lineIndex: Int, resource: Resource, preferredName: String, index: Int)]()
        var segmentIndex = 0

        for lineIndex in output.indices {
            try checkCancellation()
            let line = output[lineIndex].trimmingCharacters(in: .whitespacesAndNewlines)

            if line.hasPrefix("#EXT-X-MAP:"),
               let uri = attribute(named: "URI", in: line),
               let sourceURL = URL(string: uri) {
                jobs.append((lineIndex, Resource(url: sourceURL, byteRange: nil), "init", 0))
                continue
            }

            guard !line.isEmpty, !line.hasPrefix("#"), let sourceURL = URL(string: line) else {
                continue
            }

            segmentIndex += 1
            jobs.append((lineIndex, Resource(url: sourceURL, byteRange: nil), "segment", segmentIndex))
        }

        let limit = max(1, maximumConcurrentDownloads)
        var offset = 0

        // Download in bounded batches. This keeps URLSession busy without opening
        // every segment in a long VOD at once. Results are written back by original
        // line index, so playlist order never changes.
        while offset < jobs.count {
            try checkCancellation()
            let end = min(offset + limit, jobs.count)
            let batch = Array(jobs[offset..<end])

            let results = try await withThrowingTaskGroup(of: (Int, URL, URL, Bool).self) { group in
                for job in batch {
                    group.addTask { [weak self] in
                        guard let self else { throw UPlayerError.nullReference }
                        let localURL = try await self.cache(resource: job.resource,
                                                            preferredName: job.preferredName,
                                                            index: job.index,
                                                            directory: directory)
                        return (job.lineIndex, job.resource.url, localURL, job.preferredName == "init")
                    }
                }

                var values = [(Int, URL, URL, Bool)]()
                values.reserveCapacity(batch.count)
                for try await value in group { values.append(value) }
                return values
            }

            for (lineIndex, sourceURL, localURL, isInitialization) in results {
                let playbackURL = cachedPlaybackURL(sourceURL: sourceURL,
                                                    localURL: localURL,
                                                    mode: isInitialization ? "video-init" : "video-segment")
                if isInitialization {
                    output[lineIndex] = "#EXT-X-MAP:URI=\"\(playbackURL.absoluteString)\""
                } else {
                    output[lineIndex] = playbackURL.absoluteString
                }
            }
            offset = end
        }

        log("\(mediaCacheLogScope) cached playlist \(playlistKey), segments: \(segmentIndex), concurrent downloads: \(limit)", loggingLevel: .debug)
        return output.joined(separator: "\n")
    }

    func cache(resource: Resource,
               preferredName: String,
               index: Int,
               directory: URL) async throws -> URL {
        try checkCancellation()

        let ext = resource.url.pathExtension.isEmpty ? "mp4" : resource.url.pathExtension
        let rangeSuffix: String
        if let range = resource.byteRange {
            rangeSuffix = "-\(range.offset)-\(range.length)"
        } else {
            rangeSuffix = ""
        }

        let filename = "\(preferredName)-\(index)-\(stableIdentifier(resource.url.absoluteString))\(rangeSuffix).\(ext)"
        let localURL = directory.appendingPathComponent(filename)

        if fileManager.fileExists(atPath: localURL.path),
           let values = try? localURL.resourceValues(forKeys: [.fileSizeKey]),
           (values.fileSize ?? 0) > 0 {
            return localURL
        }

        var request = URLRequest(url: resource.url,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 30)
        requestHeaders.forEach {
            request.setValue($0.value, forHTTPHeaderField: $0.key)
        }

        if let range = resource.byteRange {
            let end = range.offset + range.length - 1
            request.setValue("bytes=\(range.offset)-\(end)", forHTTPHeaderField: "Range")
        }

        let (data, response) = try await session.data(for: request)
        try checkCancellation()

        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw UPlayerError.invalidHTTPResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        var payload = data

        // Some servers ignore Range and return 200/full content. Slice it locally so
        // the rewritten HLS resource still represents exactly one byte range.
        if let range = resource.byteRange, http.statusCode == 200 {
            let start = Int(range.offset)
            let end = start + Int(range.length)
            guard start >= 0, end <= data.count else {
                throw UPlayerError.assetLoadingFailed
            }
            payload = data.subdata(in: start..<end)
        }

        guard !payload.isEmpty else {
            throw UPlayerError.emptyDownload
        }

        let temporaryURL = localURL.appendingPathExtension("tmp")
        try? fileManager.removeItem(at: temporaryURL)
        try payload.write(to: temporaryURL, options: .atomic)
        try? fileManager.removeItem(at: localURL)
        try fileManager.moveItem(at: temporaryURL, to: localURL)

        log("\(mediaCacheLogScope) cached \(resource.url.absoluteString) -> \(localURL.path), bytes: \(payload.count)",
            loggingLevel: .debug)

        return localURL
    }
}

// MARK: - Cached playback URLs

private extension UPlayerMediaCacher {

    func requestMode(_ url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first {
            $0.name == "mode"
        }?.value
    }

    func originalHTTPURL(from url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        if components.scheme == "uplayer" { components.scheme = "https" }
        components.queryItems = (components.queryItems ?? []).filter {
            $0.name != "mode" && $0.name != "codec" && $0.name != "cacheFile"
        }
        return components.url
    }

    func audioCachedPlaybackURL(playlistURL: URL,
                                sourceURL: URL,
                                localURL: URL,
                                mode: String) -> URL {
        // Preserve codec and all original query items from an existing
        // audio-transcode URL; only attach cache transport metadata.
        guard var components = URLComponents(url: playlistURL, resolvingAgainstBaseURL: false) else {
            return cachedPlaybackURL(sourceURL: sourceURL, localURL: localURL, mode: mode)
        }
        components.scheme = "uplayer"
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "cacheFile" }
        if !items.contains(where: { $0.name == "mode" }) {
            items.append(URLQueryItem(name: "mode", value: mode))
        }
        items.append(URLQueryItem(name: "cacheFile", value: localURL.path))
        components.queryItems = items
        return components.url ?? playlistURL
    }

    /// Keep AVFoundation on the custom resource-loader path. The local file path
    /// is transport metadata only; the resource loader still reports the original
    /// HTTP(S) URL as the media identity.
    func cachedPlaybackURL(sourceURL: URL, localURL: URL, mode: String) -> URL {
        guard var components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false) else {
            return sourceURL
        }

        components.scheme = "uplayer"
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "mode" || $0.name == "cacheFile" }
        items.append(URLQueryItem(name: "mode", value: mode))
        items.append(URLQueryItem(name: "cacheFile", value: localURL.path))
        components.queryItems = items
        return components.url ?? sourceURL
    }
}

// MARK: - Parsing / state

private extension UPlayerMediaCacher {

    func playlistLines(_ value: String) -> [String] {
        value.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func attribute(named name: String, in line: String) -> String? {
        let prefix = "\(name)="
        guard let range = line.range(of: prefix) else { return nil }

        var remainder = line[range.upperBound...]
        if remainder.first == "\"" {
            remainder.removeFirst()
            guard let end = remainder.firstIndex(of: "\"") else { return nil }
            return String(remainder[..<end])
        }

        let end = remainder.firstIndex(of: ",") ?? remainder.endIndex
        return String(remainder[..<end])
    }

    /// offset == -1 means that EXT-X-BYTERANGE omitted @offset and must continue
    /// from the end of the previous range for the same resource.
    func parseByteRange(_ value: String, previousEnd: Int64?) -> ByteRange? {
        let parts = value.split(separator: "@", maxSplits: 1).map(String.init)
        guard let length = Int64(parts[0]), length > 0 else { return nil }

        if parts.count == 2, let offset = Int64(parts[1]) {
            return ByteRange(length: length, offset: offset)
        }

        return ByteRange(length: length, offset: previousEnd ?? -1)
    }

    func checkCancellation() throws {
        if isTaskCanceled.value || Task.isCancelled {
            throw UPlayerError.operationCanceled
        }
    }

    /// Stable FNV-1a identifier. Swift's hashValue is intentionally randomized and
    /// therefore unsuitable for persistent cache paths.
    func stableIdentifier(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
