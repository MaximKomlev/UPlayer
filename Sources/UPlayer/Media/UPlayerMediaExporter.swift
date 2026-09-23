//
//  UPlayerAudioTranscoder.swift
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

    /// Exports a parsed DASH asset to a regular MP4 file.
    ///
    /// UPlayerMPDParser must have already populated asset.mpdMetadata.manifest.
    @discardableResult
    public func export(asset: UPlayerAssetProtocol,
                       to outputURL: URL) async throws -> URL {
        resetCancellation()

        guard let manifest = asset.mpdMetadata?.manifest else {
            throw UPlayerError.missingManifest
        }

        let video = try selectRepresentation(type: .video, manifest: manifest)
        let audio = try? selectRepresentation(type: .audio, manifest: manifest)

        let workDirectory = fileManager.temporaryDirectory.appendingPathComponent("UPlayerExport-\(UUID().uuidString)", isDirectory: true)

        try fileManager.createDirectory(at: workDirectory,
                                        withIntermediateDirectories: true)

        defer {
            try? fileManager.removeItem(at: workDirectory)
        }

        try checkCancellation()
        reportProgress(0)

        let totalDownloads = video.segments.count + 1 + (audio.map { $0.segments.count + 1 } ?? 0)
        let progress = DownloadProgress(total: max(1, totalDownloads)) { [weak self] value in
            // Downloads are 85% of the operation. The remaining 15% is mux/export.
            self?.reportProgress(value * 0.85)
        }

        async let videoURL = makeLocalTrack(selected: video,
                                             mediaType: .video,
                                             directory: workDirectory,
                                             progress: progress)

        async let audioURL: URL? = {
            guard let audio else {
                return nil
            }
            return try await self.makeLocalTrack(selected: audio,
                                                 mediaType: .audio,
                                                 directory: workDirectory,
                                                 progress: progress)
        }()

        let localVideoURL = try await videoURL
        let localAudioURL = try await audioURL

        try checkCancellation()
        reportProgress(0.88)

        try await mux(videoURL: localVideoURL,
                      audioURL: localAudioURL,
                      outputURL: outputURL)

        try checkCancellation()
        reportProgress(1)
        return outputURL
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
        let safetyDelaySegments = max(6,
                                      Int(ceil((manifest.minimumUpdatePeriod ?? 2) / segmentDuration)) + 3)
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

        let outputURL = directory.appendingPathComponent(
            mediaType == .video ? "video.mp4" : "audio.mp4"
        )

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
                let transcoded = try await audioTranscoder.transcodeAudioSegment(
                    data: data,
                    initializationData: initializationData,
                    originalCodec: selected.representation.codecs,
                    sourceURL: segmentURL
                )
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
        try checkCancellation()

        var request = URLRequest(url: url)
        requestHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

        return try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { [weak self] data, response, error in
                guard let self else {
                    continuation.resume(throwing: UPlayerError.cancelled)
                    return
                }

                self.removeTask(withIdentifier: responseTaskIdentifier(response: response, fallback: nil))

                if self.isCancelled {
                    continuation.resume(throwing: UPlayerError.cancelled)
                    return
                }

                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                if let http = response as? HTTPURLResponse,
                   !(200..<300).contains(http.statusCode) {
                    continuation.resume(throwing: UPlayerError.invalidHTTPResponse(http.statusCode))
                    return
                }

                guard let data else {
                    continuation.resume(throwing: UPlayerError.emptyDownload)
                    return
                }

                continuation.resume(returning: data)
            }

            addTask(task)
            task.resume()
        }
    }

    // URLSessionTask is not exposed by URLResponse. Removal is also done lazily
    // before every append/cancel, so stale completed tasks are harmless.
    func removeTask(withIdentifier identifier: Int?) {
        guard let identifier else { return }
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
        result = result.replacingOccurrences(of: "$Bandwidth$", with: "\(representation.bandwidth)")

        if let segment {
            result = result.replacingOccurrences(of: "$Number$", with: "\(segment.number)")
            result = result.replacingOccurrences(of: "$Time$", with: "\(segment.time)")
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

