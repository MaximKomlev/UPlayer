//
//  UPlayerMPDParser.swift
//  UPlayer
//
//  Created by Max Komleu on 2/23/26.
//

import Combine
import Foundation
import AVFoundation

private let logScope = "[mpd parsing]"

private func parseISODuration(_ string: String) -> TimeInterval? {
    let pattern = #"^P(?:(\d+)Y)?(?:(\d+)M)?(?:(\d+)D)?T?(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?$"#

    guard
        let regex = try? NSRegularExpression(pattern: pattern),
        let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string))
    else { return nil }

    func value(at index: Int) -> Double {
        let range = match.range(at: index)
        guard let swiftRange = Range(range, in: string) else { return 0 }
        return Double(string[swiftRange]) ?? 0
    }

    return
        value(at: 3) * 86400 +
        value(at: 4) * 3600 +
        value(at: 5) * 60 +
        value(at: 6)
}

private func parseRange(_ value: String?) -> ClosedRange<Int64>? {
    guard let value else { return nil }
    let parts = value.split(separator: "-")
    guard parts.count == 2,
          let start = Int64(parts[0]),
          let end = Int64(parts[1]) else {
        return nil
    }
    return start...end
}

private struct BaseURLContext {
    var mpd: URL?
    var period: URL?
    var adaptationSet: URL?
    var representation: URL?

    func resolved() -> URL? {
        representation ?? adaptationSet ?? period ?? mpd
    }
}

private final class DASHPeriodBuilderState {
    let id: String?
    let start: TimeInterval
    let duration: TimeInterval?
    var baseURL: URL?
    var adaptationSets: [DASHAdaptationSet] = []

    init(attributes: [String: String], baseURL: URL?) {
        self.id = attributes["id"]
        self.start = attributes["start"].flatMap(parseISODuration) ?? 0
        self.duration = attributes["duration"].flatMap(parseISODuration)
        self.baseURL = baseURL
    }

    func build() -> DASHPeriod {
        DASHPeriod(
            id: id,
            start: start,
            duration: duration,
            baseURL: baseURL,
            adaptationSets: adaptationSets
        )
    }
}

private final class DASHAdaptationSetBuilderState {
    let id: String?
    var contentType: String?
    let mimeType: String?
    var baseURL: URL?

    var segmentTemplate: DASHSegmentTemplate?
    var representations: [DASHRepresentation] = []

    init(attributes: [String: String], baseURL: URL?) {
        self.id = attributes["id"]
        self.contentType = attributes["contentType"]
        self.mimeType = attributes["mimeType"]
        self.baseURL = baseURL
    }

    func build() -> DASHAdaptationSet {
        let reps = representations.map { rep in
            guard rep.segmentTemplate == nil else { return rep }
            return DASHRepresentation(
                id: rep.id,
                bandwidth: rep.bandwidth,
                width: rep.width,
                height: rep.height,
                mimeType: rep.mimeType,
                codecs: rep.codecs,
                baseURL: rep.baseURL,
                segmentTemplate: segmentTemplate,
                segmentBase: rep.segmentBase
            )
        }

        return DASHAdaptationSet(
            id: id,
            contentType: contentType,
            mimeType: mimeType,
            baseURL: baseURL,
            segmentTemplate: segmentTemplate,
            representations: reps
        )
    }
}

private final class DASHRepresentationBuilderState {

    let id: String
    let bandwidth: Int
    let width: Int?
    let height: Int?
    let mimeType: String?
    let codecs: String?
    var baseURL: URL?

    var segmentTemplate: DASHSegmentTemplate?
    var segmentBase: DASHSegmentBase?

    init(attributes: [String: String], baseURL: URL?) {
        self.id = attributes["id"] ?? UUID().uuidString
        self.bandwidth = Int(attributes["bandwidth"] ?? "") ?? 0
        self.width = Int(attributes["width"] ?? "")
        self.height = Int(attributes["height"] ?? "")
        self.mimeType = attributes["mimeType"]
        self.codecs = attributes["codecs"]
        self.baseURL = baseURL
    }

    func build() -> DASHRepresentation {
        DASHRepresentation(
            id: id,
            bandwidth: bandwidth,
            width: width,
            height: height,
            mimeType: mimeType,
            codecs: codecs,
            baseURL: baseURL,
            segmentTemplate: segmentTemplate,
            segmentBase: segmentBase
        )
    }
}

public final class UPlayerMPDParser: NSObject, UPlayerAssetProcessorProtocol {

    private let isRunningPrivate = SyncProperty(value: false)
    private var isTaskCanceled = SyncProperty<Bool>(value: false)

    private var manifestType: DASHManifestType = .staticVOD
    private var mediaPresentationDuration: TimeInterval?
    private var minimumUpdatePeriod: TimeInterval?
    private var timeShiftBufferDepth: TimeInterval?
    private var availabilityStartTime: Date?
    
    private var baseURLContext = BaseURLContext()
    private var elementStack: [String] = []
    private var currentBaseURLString = ""

    private var periods: [DASHPeriod] = []
    private var manifest: DASHManifest?

    private var currentPeriod: DASHPeriodBuilderState?
    private var currentAdaptationSet: DASHAdaptationSetBuilderState?
    private var currentRepresentation: DASHRepresentationBuilderState?

    private var currentSegmentTemplateAttributes: [String: String]?
    private var currentTimelineEntries: [DASHTimelineEntry] = []
    private var timelineSegmentNumber = 0

    private var currentSegmentBaseIndexRange: ClosedRange<Int64>?
    private var currentSegmentBaseInitializationRange: ClosedRange<Int64>?
    
    private var insideImageAdaptation = false
    private var currentImageSegmentTemplateAttributes: [String: String]?
    private var currentThumbnailTracks: [DASHThumbnailTrack] = []
    private var currentThumbnailTileValue: String?
    private var currentImageRepresentationAttributes: [String: String]?

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

        reset()
        
        switch asset.type {
        case .hls, .mp4:
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
                
                guard let data = asset.mpdMetadata?.rawData else {
                    throw UPlayerErrorsList.mpdParseNullData
                }
                
                let rootMPDURL = asset.url
                baseURLContext.mpd = rootMPDURL
                
                let parser = XMLParser(data: data)
                parser.delegate = self
                
                guard parser.parse(), let manifest = self.manifest else {
                    throw UPlayerErrorsList.mpdParseError
                }
                
                log("\(logScope) succeed, url: \(asset.url)", loggingLevel: .debug)
                manifest.baseURL = rootMPDURL
                asset.mpdMetadata?.update(manifest: manifest)
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
    
    // MARK: Helpers
    
    private func reset() {
        manifestType = .staticVOD
        mediaPresentationDuration = nil
        minimumUpdatePeriod = nil
        timeShiftBufferDepth = nil
        availabilityStartTime = nil

        baseURLContext = BaseURLContext()
        elementStack = []
        currentBaseURLString = ""

        periods = []
        manifest = nil

        currentPeriod = nil
        currentAdaptationSet = nil
        currentRepresentation = nil

        currentSegmentTemplateAttributes = nil
        currentTimelineEntries = []
        timelineSegmentNumber = 0

        currentSegmentBaseIndexRange = nil
        currentSegmentBaseInitializationRange = nil
        
        insideImageAdaptation = false
        currentImageSegmentTemplateAttributes = nil
        currentThumbnailTracks = []
        currentThumbnailTileValue = nil
        currentImageRepresentationAttributes = nil
    }
}

extension UPlayerMPDParser: XMLParserDelegate {

    public func parser(_ parser: XMLParser,
                       didStartElement elementName: String,
                       namespaceURI: String?,
                       qualifiedName qName: String?,
                       attributes: [String : String]) {
        elementStack.append(elementName)

        switch elementName {

        case "MPD":
            if attributes["type"] == "dynamic" {
                manifestType = .dynamicLive
            }
            minimumUpdatePeriod = attributes["minimumUpdatePeriod"].flatMap(parseISODuration)
            mediaPresentationDuration = attributes["mediaPresentationDuration"].flatMap(parseISODuration)
            timeShiftBufferDepth = attributes["timeShiftBufferDepth"].flatMap(parseISODuration)
            if let ast = attributes["availabilityStartTime"] {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                availabilityStartTime = formatter.date(from: ast)

                if availabilityStartTime == nil {
                    let fallback = ISO8601DateFormatter()
                    availabilityStartTime = fallback.date(from: ast)
                }
            }
        case "Period":
            currentPeriod = DASHPeriodBuilderState(
                attributes: attributes,
                baseURL: baseURLContext.resolved()
            )

        case "AdaptationSet":
            currentAdaptationSet = DASHAdaptationSetBuilderState(
                attributes: attributes,
                baseURL: baseURLContext.resolved()
            )
            insideImageAdaptation =
                attributes["contentType"] == "image" ||
                attributes["mimeType"]?.contains("image") == true

        case "Representation":
            if insideImageAdaptation {
                currentImageRepresentationAttributes = attributes
                currentThumbnailTileValue = nil
            } else {
                currentRepresentation = DASHRepresentationBuilderState(
                    attributes: attributes,
                    baseURL: baseURLContext.resolved()
                )
            }

        case "BaseURL":
            currentBaseURLString = ""

        case "SegmentTemplate":
            if insideImageAdaptation {
                currentImageSegmentTemplateAttributes = attributes
            } else {
                currentSegmentTemplateAttributes = attributes
                currentTimelineEntries = []
                timelineSegmentNumber = Int(attributes["startNumber"] ?? "") ?? 1
            }

        case "S":
            guard currentSegmentTemplateAttributes != nil else { break }

            let t = Int64(attributes["t"] ?? "") ?? 0
            let d = Int64(attributes["d"] ?? "") ?? 0
            let r = Int(attributes["r"] ?? "") ?? 0

            for i in 0...r {
                let entry = DASHTimelineEntry(
                    number: timelineSegmentNumber,
                    pts: t + Int64(i) * d,
                    duration: d
                )
                timelineSegmentNumber += 1
                currentTimelineEntries.append(entry)
            }

        case "SegmentBase":
            currentSegmentBaseIndexRange = parseRange(attributes["indexRange"])
            currentSegmentBaseInitializationRange = nil

        case "Initialization":
            if elementStack.dropLast().last == "SegmentBase" {
                currentSegmentBaseInitializationRange = parseRange(attributes["range"])
            }

        case "ContentComponent":
            if let contentType = attributes["contentType"] {
                currentAdaptationSet?.contentType = contentType
            }
  
        case "EssentialProperty":
            if insideImageAdaptation,
               (attributes["schemeIdUri"] == "http://dashif.org/thumbnail_tile" ||
                attributes["schemeIdUri"] == "http://dashif.org/guidelines/thumbnail_tile") {
                currentThumbnailTileValue = attributes["value"]
            }
            
        default:
            break
        }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        if elementStack.last == "BaseURL" {
            currentBaseURLString += string
        }
    }

    public func parser(_ parser: XMLParser,
                       didEndElement elementName: String,
                       namespaceURI: String?,
                       qualifiedName qName: String?) {
        switch elementName {

        case "BaseURL":
            resolveCurrentBaseURL()

        case "SegmentTemplate":
            guard let attrs = currentSegmentTemplateAttributes else { break }

            let template = DASHSegmentTemplate(
                timescale: Int(attrs["timescale"] ?? "") ?? 1,
                duration: Int(attrs["duration"] ?? ""),
                startNumber: Int(attrs["startNumber"] ?? "") ?? 1,
                media: attrs["media"],
                initialization: attrs["initialization"],
                timeline: currentTimelineEntries.isEmpty ? nil : currentTimelineEntries
            )

            if elementStack.dropLast().last == "Representation" {
                currentRepresentation?.segmentTemplate = template
            } else {
                currentAdaptationSet?.segmentTemplate = template
            }

            currentSegmentTemplateAttributes = nil
            currentTimelineEntries = []

        case "SegmentBase":
            currentRepresentation?.segmentBase = DASHSegmentBase(
                indexRange: currentSegmentBaseIndexRange,
                initializationRange: currentSegmentBaseInitializationRange
            )
            currentSegmentBaseIndexRange = nil
            currentSegmentBaseInitializationRange = nil

        case "Representation":
            if insideImageAdaptation {
                if let track = buildThumbnailTrack() {
                    currentThumbnailTracks.append(track)
                }

                currentImageRepresentationAttributes = nil
                currentThumbnailTileValue = nil
            } else {
                if let rep = currentRepresentation?.build() {
                    currentAdaptationSet?.representations.append(rep)
                }

                currentRepresentation = nil
                baseURLContext.representation = nil
            }

        case "AdaptationSet":
            if insideImageAdaptation {
                insideImageAdaptation = false
                currentImageSegmentTemplateAttributes = nil
            } else {
                if let set = currentAdaptationSet?.build() {
                    currentPeriod?.adaptationSets.append(set)
                }
                currentAdaptationSet = nil
                baseURLContext.adaptationSet = nil
            }
        case "Period":
            if let period = currentPeriod?.build() {
                periods.append(period)
            }
            currentPeriod = nil
            baseURLContext.period = nil

        default:
            break
        }

        elementStack.removeLast()
    }

    public func parserDidEndDocument(_ parser: XMLParser) {
        manifest = DASHManifest(type: manifestType,
                                availabilityStartTime: availabilityStartTime,
                                mediaPresentationDuration: mediaPresentationDuration,
                                minimumUpdatePeriod: minimumUpdatePeriod,
                                timeShiftBufferDepth: timeShiftBufferDepth,
                                periods: periods)
        manifest?.thumbnailTracks = currentThumbnailTracks
    }
}

private extension UPlayerMPDParser {
    func resolveCurrentBaseURL() {
        let trimmed = currentBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        let parent = baseURLContext.resolved()
        let resolved = parent.flatMap { URL(string: trimmed, relativeTo: $0)?.absoluteURL } ?? URL(string: trimmed)
        
        switch elementStack.dropLast().last {
        case "MPD":
            baseURLContext.mpd = resolved
            
        case "Period":
            baseURLContext.period = resolved
            currentPeriod?.baseURL = resolved
            
        case "AdaptationSet":
            baseURLContext.adaptationSet = resolved
            currentAdaptationSet?.baseURL = resolved
            
        case "Representation":
            baseURLContext.representation = resolved
            currentRepresentation?.baseURL = resolved
            
        default:
            break
        }
        
        currentBaseURLString = ""
    }
    
    func buildThumbnailTrack() -> DASHThumbnailTrack? {
        guard
            let repAttrs = currentImageRepresentationAttributes,
            let templateAttrs = currentImageSegmentTemplateAttributes,
            let id = repAttrs["id"],
            let media = templateAttrs["media"],
            let tileValue = currentThumbnailTileValue
        else {
            return nil
        }

        let parts = tileValue.split(separator: "x")
        guard
            parts.count == 2,
            let columns = Int(parts[0]),
            let rows = Int(parts[1])
        else {
            return nil
        }

        let imageWidth = Int(repAttrs["width"] ?? "") ?? 0
        let imageHeight = Int(repAttrs["height"] ?? "") ?? 0
        let bandwidth = Int(repAttrs["bandwidth"] ?? "") ?? 0
        let duration = TimeInterval(templateAttrs["duration"] ?? "") ?? 0
        let startNumber = Int(templateAttrs["startNumber"] ?? "") ?? 1

        return DASHThumbnailTrack(
            id: id,
            bandwidth: bandwidth,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            columns: columns,
            rows: rows,
            mediaTemplate: media,
            duration: duration,
            startNumber: startNumber,
            baseURL: baseURLContext.resolved()
        )
    }
}
