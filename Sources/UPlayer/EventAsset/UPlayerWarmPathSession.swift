//
//  UPlayerWarmPathSession.swift
//  UPlayer
//
//  Ported from `WPKWarmPathPlaybackSession.reserveNextLikelyEvent`
//  (wyze-wpk-ios, feat/kvs-prefetch-caching). Given the next likely
//  event's URL, this parses its manifest (via the same processor
//  pipeline used for normal playback) and concurrently prefetches the
//  video+audio init segments plus the next N media fragments (both
//  tracks) into `UPlayerFragmentCache`, so `UPlayerAVAssetResourceLoader`
//  can serve them from disk instead of the network once the user
//  actually swipes.
//

import Foundation

public final class UPlayerWarmPathSession: NSObject {

    /// How many leading media fragments (per representation) to prefetch
    /// ahead of playback. The old system tried 2 first and found it
    /// insufficient in real testing; 6 is the value that was kept after
    /// tuning, so it's reused here rather than re-derived.
    public static let defaultLookaheadCount = 6

    private let lookaheadCount: Int
    private let fragmentCache: UPlayerFragmentCache
    private let processorsQueue: UPlayerAssetProcessorsQueueProtocol
    private let urlSession: URLSession

    private let lock = NSLock()
    private var pendingCompletions: [URL: [(Bool) -> Void]] = [:]
    private var reservationStartTimes: [URL: Date] = [:]
    private var cacheHits = 0
    private var cacheMisses = 0

    /// The outer fragment-fetch `Task` for each asset (manifest) URL
    /// currently prefetching. Stored so `endSession()` can actually cancel
    /// in-flight network fetches, not just stop manifest parsing —
    /// previously a bare untracked `Task` here meant leaving a screen
    /// mid-prefetch never stopped the fragment downloads it kicked off.
    /// `URLSession`'s async `data(from:)` cancels its underlying
    /// `URLSessionTask` when the enclosing `Task` is cancelled, so
    /// cancelling this handle is sufficient — no separate download-task
    /// bookkeeping is needed.
    private var fetchTasks: [URL: Task<Void, Never>] = [:]

    /// Caps real fragment-fetch concurrency across ALL in-flight
    /// prefetches (every event being warmed at once), not just the
    /// resolve-call batching callers may do above this session. AWS KVS
    /// enforces a hard 3-concurrent-connection-per-stream-per-host limit
    /// shared by manifest/fragment/init fetches; without this, group-wide
    /// prefetching (multiple events' fragments overlapping freely) starves
    /// that shared budget and can stall whichever event is actively
    /// playing.
    private let fetchThrottle = UPlayerFetchThrottle(limit: 3)

    public init(lookaheadCount: Int = UPlayerWarmPathSession.defaultLookaheadCount,
                fragmentCache: UPlayerFragmentCache = .shared,
                urlSession: URLSession = .shared) {

        self.lookaheadCount = lookaheadCount
        self.fragmentCache = fragmentCache
        self.urlSession = urlSession

        let queue = UPlayerAssetProcessorsQueue()
        queue.add(processor: UPlayerMetadataDownloader(id: "warmPathDownloadAssetProcessor"))
        queue.add(processor: UPlayerMPDParser(id: "warmPathMpdParserAssetProcessor"))
        queue.add(processor: UPlayerSegmentBaseHLSGenerator(id: "warmPathHlsSegmentBaseAssetProcessor"))
        queue.add(processor: UPlayerMPDToMP4Resolver(id: "warmPathMPDToMP4ResolverAssetProcessor"))
        queue.add(processor: UPlayerHLSGenerator(id: "warmPathHlsGeneratorAssetProcessor"))
        self.processorsQueue = queue

        super.init()

        queue.delegate = self
    }

    /// Begins prefetching `url`'s manifest and its first `lookaheadCount`
    /// media fragments (video and audio tracks). Safe to call multiple
    /// times for the same URL while a prefetch is already in flight — the
    /// completion is simply appended to the pending set instead of
    /// starting duplicate work.
    ///
    /// `completion` reports `true` if at least the manifest was parsed
    /// and some fragments were queued for (or already) caching; `false` on
    /// manifest failure. It does not wait for every fragment download to
    /// finish, since those continue in the background and simply populate
    /// the cache whenever they land.
    public func reserveNextLikelyEvent(url: URL, completion: ((Bool) -> Void)? = nil) {
        lock.lock()
        let alreadyInFlight = pendingCompletions[url] != nil
        pendingCompletions[url, default: []].append(completion ?? { _ in })
        if !alreadyInFlight {
            reservationStartTimes[url] = Date()
        }
        lock.unlock()

        guard !alreadyInFlight else {
            log("[warmpath] reserve already in flight for \(url.absoluteString)", loggingLevel: .debug)
            NSLog("[UPlayerWarmPath][session] DEDUP-SKIP ts=%f url=%@", Date().timeIntervalSince1970, url.absoluteString)
            return
        }

        log("[warmpath] reserving \(url.absoluteString)", loggingLevel: .info)
        NSLog("[UPlayerWarmPath][session] RESERVE ts=%f url=%@", Date().timeIntervalSince1970, url.absoluteString)

        let asset = UPlayerAsset(url: url)
        processorsQueue.start(asset: asset)
    }

    /// Cancels any in-flight prefetch and clears pending completions.
    /// Call this on EG/Stories teardown so a warm-path fetch for an event
    /// the user never actually visited doesn't keep running.
    public func endSession() {
        processorsQueue.stop()

        lock.lock()
        let pending = pendingCompletions
        pendingCompletions.removeAll()
        reservationStartTimes.removeAll()
        let tasks = fetchTasks
        fetchTasks.removeAll()
        lock.unlock()

        // Actually stop the in-flight fragment downloads, not just manifest
        // parsing — `URLSession.data(from:)` cancels its underlying network
        // request when the enclosing `Task` is cancelled.
        tasks.values.forEach { $0.cancel() }

        pending.values.flatMap { $0 }.forEach { $0(false) }
    }

    private func completePending(for url: URL, success: Bool) {
        lock.lock()
        let completions = pendingCompletions.removeValue(forKey: url) ?? []
        let startTime = reservationStartTimes.removeValue(forKey: url)
        lock.unlock()

        if let startTime {
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            NSLog("[UPlayerWarmPath][session] FINISHED ts=%f url=%@ outcome=%@ durationMs=%d",
                  Date().timeIntervalSince1970, url.absoluteString, success ? "ready" : "failed", durationMs)
        }

        completions.forEach { $0(success) }
    }

    private func recordCacheLookup(hit: Bool, url: URL) {
        lock.lock()
        if hit { cacheHits += 1 } else { cacheMisses += 1 }
        let hits = cacheHits
        let misses = cacheMisses
        lock.unlock()
        let total = hits + misses
        let rate = total > 0 ? Double(hits) / Double(total) * 100.0 : 0
        NSLog("[UPlayerWarmPath][cache] %@ url=%@ hitRate=%.1f%% (%d/%d)",
              hit ? "HIT" : "MISS", url.lastPathComponent, rate, hits, total)
    }

    private func prefetchFragments(from asset: UPlayerAssetProtocol) {
        lock.lock()
        let manifestStart = reservationStartTimes[asset.url]
        lock.unlock()
        if let manifestStart {
            NSLog("[UPlayerWarmPath][stage] manifest url=%@ durationMs=%d",
                  asset.url.absoluteString, Int(Date().timeIntervalSince(manifestStart) * 1000))
        }

        guard let hlsMetadata = asset.hlsMetadata else {
            completePending(for: asset.url, success: false)
            return
        }

        let candidateURLs = Self.videoFragmentURLs(
            in: hlsMetadata.mediaPlaylists.values,
            lookaheadCount: lookaheadCount
        )

        guard !candidateURLs.isEmpty else {
            log("[warmpath] no media fragment URLs found for \(asset.url.absoluteString)", loggingLevel: .debug)
            completePending(for: asset.url, success: true)
            return
        }

        completePending(for: asset.url, success: true)

        let fragmentsStart = Date()
        let assetURL = asset.url
        let task = Task { [urlSession, fragmentCache, fetchThrottle] in
            await withTaskGroup(of: Void.self) { group in
                for realURL in candidateURLs {
                    group.addTask {
                        if Task.isCancelled { return }

                        if fragmentCache.data(for: realURL) != nil {
                            self.recordCacheLookup(hit: true, url: realURL)
                            return
                        }
                        self.recordCacheLookup(hit: false, url: realURL)

                        // Cross-event cap: only `limit` fragment downloads run
                        // at once across every prefetch this session has in
                        // flight, matching KVS's per-host connection budget.
                        await fetchThrottle.acquire()

                        if Task.isCancelled {
                            await fetchThrottle.release()
                            return
                        }

                        do {
                            let (data, response) = try await urlSession.data(from: realURL)

                            guard let http = response as? HTTPURLResponse,
                                  (200...299).contains(http.statusCode) else {
                                await fetchThrottle.release()
                                return
                            }

                            fragmentCache.store(data, for: realURL)
                            log("[warmpath] prefetched \(realURL.absoluteString), bytes=\(data.count)", loggingLevel: .debug)
                        } catch {
                            log("[warmpath] prefetch failed for \(realURL.absoluteString): \(error)", loggingLevel: .error)
                        }
                        await fetchThrottle.release()
                    }
                }
            }
            NSLog("[UPlayerWarmPath][stage] fragments url=%@ count=%d durationMs=%d",
                  assetURL.absoluteString, candidateURLs.count, Int(Date().timeIntervalSince(fragmentsStart) * 1000))

            self.lock.lock()
            self.fetchTasks.removeValue(forKey: assetURL)
            self.lock.unlock()
        }

        lock.lock()
        fetchTasks[assetURL] = task
        lock.unlock()
    }

    /// Parses raw HLS media-playlist text for `uplayer://` video/audio
    /// init/segment URIs (the `EXT-X-MAP` line, plus up to
    /// `lookaheadCount` following `EXTINF` media URIs) and recovers their
    /// original `https://` URL — the same key `UPlayerAVAssetResourceLoader`
    /// will look up when the segment is actually requested during
    /// playback. Covers both tracks: AVPlayer needs both video and audio
    /// data to reach `readyToPlay`, so warming video alone left audio as a
    /// live network fetch that gated readiness regardless of how warm the
    /// video track was.
    static func videoFragmentURLs<S: Sequence>(in playlists: S, lookaheadCount: Int) -> [URL] where S.Element == String {
        var results: [URL] = []

        for playlist in playlists {
            var mediaURICount = 0

            for rawLine in playlist.split(separator: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespaces)

                let uriString: String?

                if line.hasPrefix("#EXT-X-MAP:"), let range = line.range(of: "URI=\"") {
                    let remainder = line[range.upperBound...]
                    uriString = remainder.split(separator: "\"", maxSplits: 1).first.map(String.init)
                } else if !line.isEmpty, !line.hasPrefix("#") {
                    guard mediaURICount < lookaheadCount else {
                        continue
                    }
                    mediaURICount += 1
                    uriString = line
                } else {
                    uriString = nil
                }

                guard let uriString,
                      let url = URL(string: uriString),
                      url.scheme == "uplayer",
                      let mode = UPlayerURLScheme.mode(of: url),
                      ["video-segment", "video-init", "audio-transcode", "audio-transcode-init"].contains(mode),
                      let originalURL = UPlayerURLScheme.originalHTTPURL(from: url) else {
                    continue
                }

                results.append(originalURL)
            }
        }

        return results
    }
}

/// A simple counting semaphore for `async` code: at most `limit` callers
/// hold the gate at once, others suspend on `acquire()` until a slot is
/// `release()`d. Used to cap real fragment-fetch concurrency across every
/// prefetch `UPlayerWarmPathSession` has in flight at once (not just within
/// a single event's own fragment list), matching AWS KVS's documented
/// hard 3-concurrent-connection-per-stream-per-host limit.
private actor UPlayerFetchThrottle {
    private let limit: Int
    private var current = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
    }

    func acquire() async {
        if current < limit {
            current += 1
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    func release() {
        if !waiters.isEmpty {
            // Hand the just-freed slot straight to the next waiter instead
            // of decrementing `current` — it's still occupied, just by a
            // different caller now.
            waiters.removeFirst().resume()
        } else {
            current -= 1
        }
    }
}

extension UPlayerWarmPathSession: UPlayerAssetProcessorsQueueDelegate {
    public func didStartProcessing(source: UPlayerAssetProcessorsQueueProtocol) {}

    public func didFinishProcessing(source: UPlayerAssetProcessorsQueueProtocol, error: Error?) {
        // No per-asset context is available on failure; every still-pending
        // reservation fails closed rather than hanging forever.
        lock.lock()
        let pending = pendingCompletions
        pendingCompletions.removeAll()
        reservationStartTimes.removeAll()
        lock.unlock()

        NSLog("[UPlayerWarmPath][session] PROCESSING-FAILED ts=%f error=%@",
              Date().timeIntervalSince1970, String(describing: error))
        pending.values.flatMap { $0 }.forEach { $0(false) }
    }

    public func didFinishProcessing(source: UPlayerAssetProcessorsQueueProtocol, asset: UPlayerAssetProtocol) {
        prefetchFragments(from: asset)
    }
}
