//
//  UPlayerFragmentCache.swift
//  UPlayer
//
//  Disk-backed cache for video/audio media fragment bytes, ported from
//  `WPKDiskFragmentStoreAdapter` (wyze-wpk-ios, feat/kvs-prefetch-caching).
//
//  This is the piece that turns a prefetched fragment into "no network
//  request": `UPlayerAVAssetResourceLoader` consults this cache before
//  making a live HTTP fetch, and `UPlayerWarmPathSession` populates it
//  ahead of playback for the next likely event.
//

import Foundation
import CryptoKit

/// Disk-backed, LRU-evicted cache of raw fragment bytes, keyed by the
/// original (pre-rewrite) fragment URL.
///
/// Not an in-memory `NSCache`: fragments are written to
/// `.cachesDirectory` so a 200MB budget of prefetched video/audio bytes can
/// survive across EG navigation without holding it all in RAM, matching the
/// design and tuning of the old `WPKDiskFragmentStoreAdapter`.
public final class UPlayerFragmentCache {

    public static let shared = UPlayerFragmentCache(budgetBytes: 200 * 1024 * 1024)

    private let budgetBytes: Int
    private let directory: URL
    private let queue = DispatchQueue(label: "com.wyze.uplayer.fragmentcache", qos: .utility)
    private let fileManager = FileManager.default

    public init(budgetBytes: Int, directoryName: String = "UPlayerFragmentCache") {
        self.budgetBytes = budgetBytes

        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.directory = caches.appendingPathComponent(directoryName, isDirectory: true)

        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Returns cached bytes for `url` if present, without touching the
    /// network. Also refreshes the entry's modification date so it isn't
    /// the next thing evicted (LRU semantics).
    public func data(for url: URL) -> Data? {
        let path = filePath(for: url)

        return queue.sync {
            guard let data = try? Data(contentsOf: path) else {
                return nil
            }

            touch(path)
            return data
        }
    }

    /// Stores `data` for `url`, evicting the least-recently-used entries
    /// first if this write would exceed the configured budget.
    public func store(_ data: Data, for url: URL) {
        let path = filePath(for: url)

        queue.async { [weak self] in
            guard let self else { return }

            do {
                try data.write(to: path, options: .atomic)
            } catch {
                log("[fragmentcache] failed to write \(url.absoluteString): \(error)",
                    loggingLevel: .error)
                return
            }

            self.evictIfNeeded()
        }
    }

    /// Removes every cached fragment. Call on session teardown (EG
    /// navigation away from Stories, logout, low-memory, etc.) so a long
    /// session doesn't hold onto stale/irrelevant fragments indefinitely.
    public func removeAll() {
        queue.async { [weak self] in
            guard let self else { return }
            guard let contents = try? self.fileManager.contentsOfDirectory(
                at: self.directory,
                includingPropertiesForKeys: nil
            ) else {
                return
            }

            for fileURL in contents {
                try? self.fileManager.removeItem(at: fileURL)
            }
        }
    }

    // MARK: - Private

    private func filePath(for url: URL) -> URL {
        directory.appendingPathComponent(md5(url.absoluteString))
    }

    private func touch(_ path: URL) {
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: path.path)
    }

    /// Evicts oldest-by-modification-date files until total size is back
    /// under budget. Runs on `queue`, so it must only ever be called from
    /// a block already scheduled on `queue`.
    private func evictIfNeeded() {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else {
            return
        }

        var sized: [(url: URL, size: Int, modified: Date)] = entries.compactMap { fileURL in
            guard let values = try? fileURL.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey]
            ),
                  let size = values.fileSize,
                  let modified = values.contentModificationDate else {
                return nil
            }
            return (fileURL, size, modified)
        }

        var totalSize = sized.reduce(0) { $0 + $1.size }

        guard totalSize > budgetBytes else {
            return
        }

        sized.sort { $0.modified < $1.modified }

        for entry in sized {
            guard totalSize > budgetBytes else {
                break
            }

            try? fileManager.removeItem(at: entry.url)
            totalSize -= entry.size
        }
    }

    private func md5(_ string: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
