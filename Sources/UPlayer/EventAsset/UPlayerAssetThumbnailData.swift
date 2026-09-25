//
//  UPlayerAssetThumbnailData.swift
//  UPlayer
//
//  Created by Max Komleu on 4/27/26.
//

import UIKit
import Foundation

public final class UPlayerThumbnailSprite {
    public let url: URL
    public let data: Data

    public init(url: URL, data: Data) {
        self.url = url
        self.data = data
    }

    public var image: UIImage? {
        UIImage(data: data)
    }
}

public protocol UPlayerAssetThumbnailDataProtocol: AnyObject {
    var track: DASHThumbnailTrack { get }
    var sprites: [URL: UPlayerThumbnailSprite] { get }
    var cues: [DASHThumbnailCue] { get }

    func cue(for time: TimeInterval) -> DASHThumbnailCue?
    func sprite(for cue: DASHThumbnailCue) -> UPlayerThumbnailSprite?
    func image(for cue: DASHThumbnailCue) -> UIImage?
}

public final class UPlayerAssetThumbnailData: UPlayerAssetThumbnailDataProtocol {

    public let track: DASHThumbnailTrack
    public let sprites: [URL: UPlayerThumbnailSprite]
    public let cues: [DASHThumbnailCue]

    public init(
        track: DASHThumbnailTrack,
        sprites: [URL: UPlayerThumbnailSprite],
        cues: [DASHThumbnailCue]
    ) {
        self.track = track
        self.sprites = sprites
        self.cues = cues
    }

    public func cue(for time: TimeInterval) -> DASHThumbnailCue? {
        guard time.isFinite, !cues.isEmpty else {
            return nil
        }

        // Cues are generated in chronological order. Binary search avoids a
        // linear scan for every UISlider valueChanged event while scrubbing.
        var lowerBound = 0
        var upperBound = cues.count - 1

        while lowerBound <= upperBound {
            let index = lowerBound + (upperBound - lowerBound) / 2
            let cue = cues[index]

            if time < cue.timeRange.lowerBound {
                upperBound = index - 1
            } else if time >= cue.timeRange.upperBound {
                lowerBound = index + 1
            } else {
                return cue
            }
        }

        return nil
    }

    public func sprite(for cue: DASHThumbnailCue) -> UPlayerThumbnailSprite? {
        sprites[cue.imageURL]
    }
    
    public func image(for cue: DASHThumbnailCue) -> UIImage? {
        let key = UPlayerThumbnailImageCacheKey(cue: cue)

        if let cached = UPlayerThumbnailCache.shared.image(for: key) {
            return cached
        }

        guard let sprite = sprite(for: cue),
              let spriteImage = UIImage(data: sprite.data),
              let cgImage = spriteImage.cgImage else {
            return nil
        }

        let scale = spriteImage.scale

        let cropRect = CGRect(
            x: cue.sourceRect.origin.x * scale,
            y: cue.sourceRect.origin.y * scale,
            width: cue.sourceRect.width * scale,
            height: cue.sourceRect.height * scale
        )

        guard let croppedCGImage = cgImage.cropping(to: cropRect) else {
            return nil
        }

        let image = UIImage(
            cgImage: croppedCGImage,
            scale: scale,
            orientation: spriteImage.imageOrientation
        )

        UPlayerThumbnailCache.shared.storeImage(image, for: key)
        return image
    }
}
