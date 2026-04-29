//
//  UPlayerAsset.swift
//  UPlayer
//
//  Created by Max Komleu on 2/23/26.
//

import Foundation
import AVFoundation

public enum UPlayerAssetType {
    case unknown
    case mp4
    case mpd(_ type: Int) // 0 - SegmentTemplate, 1 - SegmentBase
    case hls
}

public protocol UPlayerAssetProtocol: AnyObject {

    var url: URL { get }
    var type: UPlayerAssetType { get set }

    var duration: TimeInterval { get set }
    var videoRatio: Double { get set }

    var httpMetadata: UPlayerAssetHttpDataProtocol? { get set }
    var mpdMetadata: UPlayerAssetMPDDataProtocol? { get set }
    var hlsMetadata: UPlayerAssetHLSDataProtocol? { get set }
    var thumbnailMetadata: UPlayerAssetThumbnailDataProtocol? { get set }
    
    init(url: URL)
    
    func addAssetLoader(_ loader: UPlayerAVAssetResourceLoaderProtocol)
}

public class UPlayerAsset: UPlayerAssetProtocol {
    
    // MARK: Fields
    
    private var avAssetLoader: UPlayerAVAssetResourceLoaderProtocol?
    
    // MARK: UPlayerAssetProtocol

    public private(set) var url: URL

    public var type: UPlayerAssetType = .unknown
    
    public var duration: TimeInterval = 0
    public var videoRatio: Double = 9 / 16

    public var httpMetadata: UPlayerAssetHttpDataProtocol?
    public var mpdMetadata: UPlayerAssetMPDDataProtocol?
    public var hlsMetadata: UPlayerAssetHLSDataProtocol?

    public var thumbnailMetadata: (any UPlayerAssetThumbnailDataProtocol)?
    
    public required init(url: URL) {
        self.url = url
    }
    
    public func addAssetLoader(_ loader: UPlayerAVAssetResourceLoaderProtocol) {
        avAssetLoader = loader
        avAssetLoader?.dataDelegate = self
    }
}

extension UPlayerAsset: UPlayerAVAssetResourceLoaderDelegate {
    public func getPlaylist(source: UPlayerAVAssetResourceLoaderProtocol, url: URL) -> String? {
        let requestedName = url.deletingPathExtension().lastPathComponent
        let assetName = self.url.deletingPathExtension().lastPathComponent

        if requestedName == assetName {
            return hlsMetadata?.master
        }

        return hlsMetadata?.mediaPlaylists["\(requestedName).m3u8"]
    }
}
