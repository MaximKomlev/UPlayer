//
//  UPlayerMediaCacher.swift
//  UPlayer
//
//  Created by Max Komleu on 9/23/26.
//

//  Caches generated HLS video media locally and rewrites video resources to
//  uplayer:// URLs. The resource loader serves cached bytes while preserving the
//  original HTTP(S) media identity expected by AVFoundation.
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

public final class UPlayerMediaCacher: UPlayerAssetProcessorProtocol {

    private let isRunningPrivate = SyncProperty(value: false)
    private let isTaskCanceled = SyncProperty(value: false)
    private let fileManager: FileManager
    private let session: URLSession
    private var processingTask: Task<Void, Never>?

    public let id: String

    /// Headers applied to video initialization/media requests.
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

    /// Root directory used by the cache. Each asset gets its own deterministic subdirectory.
    public let cacheDirectory: URL

    public required convenience init(id: String) {
        let directory = FileManager.default.urls(for: .cachesDirectory,
                                                 in: .userDomainMask).first!
            .appendingPathComponent("UPlayerMediaCache", isDirectory: true)
        self.init(id: id, cacheDirectory: directory)
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

                    log("\(mediaCacheLogScope) selected video playlist \(selectedVariant.key), bandwidth: \(selectedVariant.bandwidth ?? -1), available video playlists: \(videoVariants.count)",
                        loggingLevel: .debug)

                    let assetDirectory = self.cacheDirectory
                        .appendingPathComponent(self.stableIdentifier(asset.url.absoluteString),
                                                isDirectory: true)

                    try self.fileManager.createDirectory(at: assetDirectory,
                                                         withIntermediateDirectories: true)

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

                    // Keep audio/thumbnail playlists untouched, but expose only the
                    // selected cached video representation in the master playlist.
                    var updatedPlaylists = hlsMetadata.mediaPlaylists
                    updatedPlaylists[selectedVariant.key] = updated
                    hlsMetadata.mediaPlaylists = updatedPlaylists
                    hlsMetadata.master = self.masterKeepingOnlySelectedVideo(master: hlsMetadata.master,
                                                                              selected: selectedVariant,
                                                                              mediaPlaylists: hlsMetadata.mediaPlaylists)

                    log("\(mediaCacheLogScope) succeed, cached video playlists: 1/\(videoVariants.count), url: \(asset.url)",
                        loggingLevel: .debug)
                    promise(.success(asset))
                } catch {
                    log("\(mediaCacheLogScope) failed, url: \(asset.url), error: \(error)",
                        loggingLevel: .error)
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

    func cacheVideoPlaylist(_ playlist: String,
                            playlistKey: String,
                            directory: URL) async throws -> String {
        // SegmentTemplate/fMP4 playlists use one URL per complete segment. Cache
        // those files concurrently. SegmentBase playlists use EXT-X-BYTERANGE and
        // stay on the sequential path below so implicit offsets remain correct.
        if !playlist.contains("#EXT-X-BYTERANGE:") &&
            !playlist.contains("BYTERANGE=") {
            return try await cacheWholeSegmentPlaylist(playlist,
                                                       playlistKey: playlistKey,
                                                       directory: directory)
        }

        let lines = playlist.components(separatedBy: .newlines)
        var output = [String]()
        output.reserveCapacity(lines.count)

        var pendingByteRange: ByteRange?
        var previousRangeEndByURL = [String: Int64]()
        var segmentIndex = 0

        for rawLine in lines {
            try checkCancellation()

            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if line.hasPrefix("#EXT-X-MAP:") {
                guard let uri = attribute(named: "URI", in: line),
                      let sourceURL = URL(string: uri) else {
                    output.append(rawLine)
                    continue
                }

                let byteRange = attribute(named: "BYTERANGE", in: line)
                    .flatMap { parseByteRange($0, previousEnd: nil) }

                let localURL = try await cache(resource: Resource(url: sourceURL,
                                                                  byteRange: byteRange),
                                               preferredName: "init",
                                               index: 0,
                                               directory: directory)

                // The cached file contains exactly the requested initialization bytes,
                // so BYTERANGE must not remain in the rewritten playlist.
                let playbackURL = cachedPlaybackURL(sourceURL: sourceURL, localURL: localURL, mode: "video-init")
                output.append("#EXT-X-MAP:URI=\"\(playbackURL.absoluteString)\"")
                continue
            }

            if line.hasPrefix("#EXT-X-BYTERANGE:") {
                let value = String(line.dropFirst("#EXT-X-BYTERANGE:".count))
                // We need the URI from the following line before an omitted offset can
                // be resolved. Store the raw length/offset temporarily.
                pendingByteRange = parseByteRange(value, previousEnd: nil)
                // Do not copy this tag: each cached file contains only this range.
                continue
            }

            if line.isEmpty || line.hasPrefix("#") {
                output.append(rawLine)
                continue
            }

            guard let sourceURL = URL(string: line) else {
                output.append(rawLine)
                continue
            }

            var resolvedRange = pendingByteRange
            if let range = pendingByteRange,
               range.offset < 0,
               let previousEnd = previousRangeEndByURL[sourceURL.absoluteString] {
                resolvedRange = ByteRange(length: range.length, offset: previousEnd)
            }

            // parseByteRange uses -1 as the marker for an omitted offset.
            if let range = resolvedRange, range.offset < 0 {
                throw UPlayerError.assetLoadingFailed
            }

            segmentIndex += 1
            let localURL = try await cache(resource: Resource(url: sourceURL,
                                                              byteRange: resolvedRange),
                                           preferredName: "segment",
                                           index: segmentIndex,
                                           directory: directory)
            let playbackURL = cachedPlaybackURL(sourceURL: sourceURL, localURL: localURL, mode: "video-segment")
            output.append(playbackURL.absoluteString)

            if let range = resolvedRange {
                previousRangeEndByURL[sourceURL.absoluteString] = range.offset + range.length
            }
            pendingByteRange = nil
        }

        log("\(mediaCacheLogScope) cached playlist \(playlistKey), segments: \(segmentIndex)",
            loggingLevel: .debug)

        return output.joined(separator: "\n")
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

        log("\(mediaCacheLogScope) cached playlist \(playlistKey), segments: \(segmentIndex), concurrent downloads: \(limit)",
            loggingLevel: .debug)
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
