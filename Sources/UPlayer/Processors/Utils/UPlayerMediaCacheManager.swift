//
//  UPlayerMediaCacheManager.swift
//  UPlayer
//
//  Created by Max Komleu on 9/24/26.
//

//
//  Persistent media-cache metadata and eviction policy.
//

import Foundation

final class UPlayerMediaCacheManager {
    static let metadataFilename = ".uplayer-cache-metadata.json"

    struct Metadata: Codable {
        let assetURL: String
        let createdAt: Date
        var lastAccessAt: Date
    }

    private let rootDirectory: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    init(rootDirectory: URL, fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
    }

    func register(assetURL: URL, directory: URL) throws {
        lock.lock(); defer { lock.unlock() }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let metadataURL = directory.appendingPathComponent(Self.metadataFilename)
        let now = Date()
        var metadata = readMetadata(at: metadataURL) ?? Metadata(assetURL: assetURL.absoluteString,
                                                                  createdAt: now,
                                                                  lastAccessAt: now)
        metadata.lastAccessAt = now
        try write(metadata, to: metadataURL)
    }

    /// Marks the asset containing a cached fragment as recently used. The write is
    /// intentionally throttled so AVPlayer requesting many fragments does not cause
    /// one metadata write per segment.
    func touch(fileURL: URL, minimumWriteInterval: TimeInterval = 60) {
        lock.lock(); defer { lock.unlock() }
        guard let assetDirectory = assetDirectory(containing: fileURL) else { return }
        let metadataURL = assetDirectory.appendingPathComponent(Self.metadataFilename)
        guard var metadata = readMetadata(at: metadataURL) else { return }
        let now = Date()
        guard now.timeIntervalSince(metadata.lastAccessAt) >= minimumWriteInterval else { return }
        metadata.lastAccessAt = now
        try? write(metadata, to: metadataURL)
    }

    /// Removes expired assets first, then evicts least-recently-used assets until
    /// the cache is within `maximumSize`. `excludedDirectory` is the asset currently
    /// being built/used and is never removed by this pass.
    func cleanup(expirationInterval: TimeInterval?,
                 maximumSize: Int64?,
                 excluding excludedDirectory: URL? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard fileManager.fileExists(atPath: rootDirectory.path) else { return }

        var entries = assetEntries(excluding: excludedDirectory)
        let now = Date()

        if let expirationInterval, expirationInterval >= 0 {
            for entry in entries where now.timeIntervalSince(entry.metadata.lastAccessAt) > expirationInterval {
                try? fileManager.removeItem(at: entry.directory)
            }
            entries = assetEntries(excluding: excludedDirectory)
        }

        guard let maximumSize, maximumSize >= 0 else { return }
        var total = directorySize(rootDirectory)
        guard total > maximumSize else { return }

        for entry in entries.sorted(by: { $0.metadata.lastAccessAt < $1.metadata.lastAccessAt }) {
            let size = directorySize(entry.directory)
            do {
                try fileManager.removeItem(at: entry.directory)
                total = max(0, total - size)
            } catch {
                continue
            }
            if total <= maximumSize { break }
        }
    }

    /// Removes abandoned whole-object SegmentBase downloads left behind if the app
    /// was terminated before the normal defer cleanup could run.
    func cleanupTemporarySegmentBaseFiles(olderThan age: TimeInterval = 60 * 60) {
        lock.lock(); defer { lock.unlock() }
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("UPlayerSegmentBase", isDirectory: true)
        guard let urls = try? fileManager.contentsOfDirectory(at: directory,
                                                               includingPropertiesForKeys: [.contentModificationDateKey],
                                                               options: [.skipsHiddenFiles]) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for url in urls {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if date < cutoff { try? fileManager.removeItem(at: url) }
        }
    }

    private struct Entry {
        let directory: URL
        let metadata: Metadata
    }

    private func assetEntries(excluding excludedDirectory: URL?) -> [Entry] {
        guard let directories = try? fileManager.contentsOfDirectory(at: rootDirectory,
                                                                      includingPropertiesForKeys: [.isDirectoryKey],
                                                                      options: [.skipsHiddenFiles]) else { return [] }
        let excludedPath = excludedDirectory?.standardizedFileURL.path
        return directories.compactMap { directory in
            guard directory.standardizedFileURL.path != excludedPath,
                  (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            let metadataURL = directory.appendingPathComponent(Self.metadataFilename)
            guard let metadata = readMetadata(at: metadataURL) else { return nil }
            return Entry(directory: directory, metadata: metadata)
        }
    }

    private func assetDirectory(containing fileURL: URL) -> URL? {
        let rootPath = rootDirectory.standardizedFileURL.path
        var current = fileURL.deletingLastPathComponent().standardizedFileURL
        while current.path.hasPrefix(rootPath) && current.path != rootPath {
            if fileManager.fileExists(atPath: current.appendingPathComponent(Self.metadataFilename).path) {
                return current
            }
            current.deleteLastPathComponent()
        }
        return nil
    }

    private func readMetadata(at url: URL) -> Metadata? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Metadata.self, from: data)
    }

    private func write(_ metadata: Metadata, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metadata)
        try data.write(to: url, options: .atomic)
    }

    private func directorySize(_ directory: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(at: directory,
                                                       includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                                       options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}
