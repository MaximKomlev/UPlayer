//
//  UPlayerMPDToMP4Resolver.swift
//  UPlayer
//
//  Created by Max Komleu on 3/11/26.
//

import Combine
import Foundation
import AVFoundation

private let logScope = "[mp4 resolve]"

public final class UPlayerMPDToMP4Resolver: UPlayerAssetProcessorProtocol {

    private let isRunningPrivate = SyncProperty(value: false)
    private var isTaskCanceled = SyncProperty<Bool>(value: false)

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

        return Future { [weak self] promise in
            guard let self else {
                promise(.failure(UPlayerErrorsList.nullReference))
                return
            }

            defer {
                self.isRunningPrivate.set { $0 = false }
            }

            if self.isTaskCanceled.value {
                promise(.failure(UPlayerErrorsList.operationCanceled))
                return
            }

            guard let manifest = asset.mpdMetadata?.manifest else {
                promise(.failure(UPlayerErrorsList.mpdParseNullData))
                return
            }

            // Only handle SegmentBase-based MPDs here
            guard manifest.containsSegmentBaseMedia() else {
                promise(.success(asset))
                return
            }

            guard let representation = manifest.bestVideoRepresentation() else {
                promise(.failure(UPlayerErrorsList.mpdParseError))
                return
            }

            guard let resolvedURL = self.buildRepresentationMediaURL(
                manifest: manifest,
                representation: representation
            ) else {
                promise(.failure(UPlayerErrorsList.mpdParseError))
                return
            }

            log("\(logScope) resolved mp4 url: \(resolvedURL.absoluteString)", loggingLevel: .debug)

            asset.type = .mp4
            asset.httpMetadata = UPlayerAssetHttpData(url: resolvedURL)
            promise(.success(asset))
        }
        .eraseToAnyPublisher()
    }

    public func cancel() {
        isTaskCanceled.set { $0 = true }
    }
}

private extension UPlayerMPDToMP4Resolver {
    func buildRepresentationMediaURL(manifest: DASHManifest,
                                     representation: DASHRepresentation) -> URL? {
        let mpdDirectoryURL = manifest.baseURL?.deletingLastPathComponent()

        for period in manifest.periods {
            for adaptation in period.adaptationSets {
                for rep in adaptation.representations where rep.id == representation.id {

                    if let repURL = resolveURL(rep.baseURL, relativeTo: mpdDirectoryURL) {
                        return repURL
                    }

                    if let adaptationURL = resolveURL(adaptation.baseURL, relativeTo: mpdDirectoryURL) {
                        return adaptationURL
                    }

                    if let periodURL = resolveURL(period.baseURL, relativeTo: mpdDirectoryURL) {
                        return periodURL
                    }
                }
            }
        }

        return nil
    }

    func resolveURL(_ url: URL?, relativeTo baseURL: URL?) -> URL? {
        guard let url else {
            return nil
        }

        if url.scheme != nil {
            return url
        }

        guard let baseURL else {
            return url
        }

        return URL(string: url.relativeString, relativeTo: baseURL)?.absoluteURL
    }
}
