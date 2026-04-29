//
//  UPlayerAssetMPDData.swift
//  UPlayer
//
//  Created by Max Komleu on 2/23/26.
//

import Foundation
import AVFoundation
import CoreGraphics

public enum DASHManifestType: CustomStringConvertible {
    case staticVOD
    case dynamicLive

    public var description: String {
        switch self {
        case .staticVOD: return "static-vod"
        case .dynamicLive: return "dynamic-live"
        }
    }
}

public enum DASHMediaType: CustomStringConvertible {
    case video
    case audio
    case image
    case subtitles
    case unknown

    public var description: String {
        switch self {
        case .video: return "video"
        case .audio: return "audio"
        case .image: return "image"
        case .subtitles: return "subtitles"
        case .unknown: return "unknown"
        }
    }
}

public final class DASHManifest {
    let type: DASHManifestType
    let availabilityStartTime: Date?
    let mediaPresentationDuration: TimeInterval?
    let minimumUpdatePeriod: TimeInterval?
    let timeShiftBufferDepth: TimeInterval?
    let periods: [DASHPeriod]
    var thumbnailTracks: [DASHThumbnailTrack] = []
    
    var baseURL: URL?

    init(type: DASHManifestType,
         availabilityStartTime: Date?,
         mediaPresentationDuration: TimeInterval?,
         minimumUpdatePeriod: TimeInterval?,
         timeShiftBufferDepth: TimeInterval?,
         baseURL: URL? = nil,
         periods: [DASHPeriod]) {
        self.type = type
        self.availabilityStartTime = availabilityStartTime
        self.mediaPresentationDuration = mediaPresentationDuration
        self.minimumUpdatePeriod = minimumUpdatePeriod
        self.timeShiftBufferDepth = timeShiftBufferDepth
        self.baseURL = baseURL
        self.periods = periods
    }

    func mediaRepresentations() -> [DASHRepresentation] {
        periods
            .flatMap(\.adaptationSets)
            .filter { $0.type == .video || $0.type == .audio }
            .flatMap(\.representations)
    }
    
    func bestVideoRepresentation() -> DASHRepresentation? {
        mediaRepresentations()
            .sorted { $0.bandwidth > $1.bandwidth }
            .first
    }

    func containsSegmentBaseMedia() -> Bool {
        periods
            .flatMap(\.adaptationSets)
            .filter { $0.type == .video || $0.type == .audio }
            .flatMap(\.representations)
            .contains { $0.segmentBase != nil }
    }

    func containsSegmentTemplateMedia() -> Bool {
        periods
            .flatMap(\.adaptationSets)
            .filter { $0.type == .video || $0.type == .audio  }
            .flatMap(\.representations)
            .contains { $0.segmentTemplate != nil }
    }
}

public final class DASHPeriod {
    let id: String?
    let start: TimeInterval
    let duration: TimeInterval?
    let baseURL: URL?
    let adaptationSets: [DASHAdaptationSet]

    init(id: String?,
         start: TimeInterval,
         duration: TimeInterval?,
         baseURL: URL?,
         adaptationSets: [DASHAdaptationSet]) {
        self.id = id
        self.start = start
        self.duration = duration
        self.baseURL = baseURL
        self.adaptationSets = adaptationSets
    }
}

public final class DASHAdaptationSet {
    let id: String?
    let contentType: String?
    let mimeType: String?
    let baseURL: URL?
    let segmentTemplate: DASHSegmentTemplate?
    let representations: [DASHRepresentation]

    let type: DASHMediaType

    init(id: String?,
         contentType: String?,
         mimeType: String?,
         baseURL: URL?,
         segmentTemplate: DASHSegmentTemplate?,
         representations: [DASHRepresentation]) {
        self.id = id
        self.contentType = contentType
        self.mimeType = mimeType
        self.baseURL = baseURL
        self.segmentTemplate = segmentTemplate
        self.representations = representations

        self.type = Self.detectType(contentType: contentType,
                                    mimeType: mimeType,
                                    representations: representations)
    }

    private static func detectType(contentType: String?,
                                   mimeType: String?,
                                   representations: [DASHRepresentation]) -> DASHMediaType {
        if let contentType {
            switch contentType {
            case "video": return .video
            case "audio": return .audio
            case "image": return .image
            case "text", "subtitle", "subtitles": return .subtitles
            default: break
            }
        }

        if let mimeType {
            if mimeType.contains("video") { return .video }
            if mimeType.contains("audio") { return .audio }
            if mimeType.contains("image") { return .image }
            if mimeType.contains("text") { return .subtitles }
        }

        if let repMime = representations.first?.mimeType {
            if repMime.contains("video") { return .video }
            if repMime.contains("audio") { return .audio }
            if repMime.contains("image") { return .image }
            if repMime.contains("text") { return .subtitles }
        }

        if let codecs = representations.first?.codecs {
            if codecs.contains("avc") || codecs.contains("hev") || codecs.contains("hvc") {
                return .video
            }
            if codecs.contains("mp4a") {
                return .audio
            }
        }

        return .unknown
    }
}

public final class DASHRepresentation {
    let id: String
    let bandwidth: Int
    let width: Int?
    let height: Int?
    let mimeType: String?
    let codecs: String?
    let baseURL: URL?
    let segmentTemplate: DASHSegmentTemplate?
    let segmentBase: DASHSegmentBase?

    init(id: String,
         bandwidth: Int,
         width: Int?,
         height: Int?,
         mimeType: String?,
         codecs: String?,
         baseURL: URL?,
         segmentTemplate: DASHSegmentTemplate?,
         segmentBase: DASHSegmentBase?) {
        self.id = id
        self.bandwidth = bandwidth
        self.width = width
        self.height = height
        self.mimeType = mimeType
        self.codecs = codecs
        self.baseURL = baseURL
        self.segmentTemplate = segmentTemplate
        self.segmentBase = segmentBase
    }
}

public final class DASHSegmentTemplate {
    let timescale: Int
    let duration: Int?
    let startNumber: Int
    let media: String?
    let initialization: String?
    let timeline: [DASHTimelineEntry]?

    init(timescale: Int,
         duration: Int?,
         startNumber: Int,
         media: String?,
         initialization: String?,
         timeline: [DASHTimelineEntry]?) {
        self.timescale = timescale
        self.duration = duration
        self.startNumber = startNumber
        self.media = media
        self.initialization = initialization
        self.timeline = timeline
    }
}

public final class DASHSegmentBase {
    let indexRange: ClosedRange<Int64>?
    let initializationRange: ClosedRange<Int64>?

    init(indexRange: ClosedRange<Int64>?,
         initializationRange: ClosedRange<Int64>?) {
        self.indexRange = indexRange
        self.initializationRange = initializationRange
    }
}

public final class DASHTimelineEntry {
    let number: Int
    let pts: Int64
    let duration: Int64

    init(number: Int, pts: Int64, duration: Int64) {
        self.number = number
        self.pts = pts
        self.duration = duration
    }
}

public final class DASHSegment {
    let number: Int
    let time: Int64
    let duration: Int64

    init(number: Int, time: Int64, duration: Int64) {
        self.number = number
        self.time = time
        self.duration = duration
    }
}

public final class DASHThumbnailTrack {
    let id: String
    let bandwidth: Int
    let imageWidth: Int
    let imageHeight: Int
    let columns: Int
    let rows: Int
    let tileWidth: Int
    let tileHeight: Int
    let mediaTemplate: String
    let duration: TimeInterval
    let startNumber: Int
    let baseURL: URL?

    init(id: String,
         bandwidth: Int,
         imageWidth: Int,
         imageHeight: Int,
         columns: Int,
         rows: Int,
         mediaTemplate: String,
         duration: TimeInterval,
         startNumber: Int,
         baseURL: URL?
    ) {
        self.id = id
        self.bandwidth = bandwidth
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.columns = columns
        self.rows = rows
        self.tileWidth = Int(ceil(Double(imageWidth) / Double(columns)))
        self.tileHeight = Int(ceil(Double(imageHeight) / Double(rows)))
        self.mediaTemplate = mediaTemplate
        self.duration = duration
        self.startNumber = startNumber
        self.baseURL = baseURL
    }
}

public final class DASHThumbnailCue {
    public let imageURL: URL
    public let sourceRect: CGRect
    public let timeRange: Range<TimeInterval>
    public let thumbnailSize: CGSize

    public init(
        imageURL: URL,
        sourceRect: CGRect,
        timeRange: Range<TimeInterval>,
        thumbnailSize: CGSize
    ) {
        self.imageURL = imageURL
        self.sourceRect = sourceRect
        self.timeRange = timeRange
        self.thumbnailSize = thumbnailSize
    }

    public func contains(time: TimeInterval) -> Bool {
        timeRange.contains(time)
    }
}

public protocol UPlayerAssetMPDDataProtocol: AnyObject {
    var rawData: Data { get }
    
    var manifest: DASHManifest? { get }
    
    init(rawData: Data)
    
    func update(manifest: DASHManifest)
}

public class UPlayerAssetMPDData: UPlayerAssetMPDDataProtocol {
    
    public var rawData: Data

    public var manifest: DASHManifest?

    public required init(rawData: Data) {
        self.rawData = rawData
    }
    
    public func update(manifest: DASHManifest) {
        self.manifest = manifest
    }
}
