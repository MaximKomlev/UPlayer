//
//  UPlayerThumbnailCache.swift
//  UPlayer
//
//  Created by Max Komleu on 4/28/26.
//

import UIKit

public struct UPlayerThumbnailImageCacheKey: Hashable {
    public let spriteURL: String
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(cue: DASHThumbnailCue) {
        self.spriteURL = cue.imageURL.absoluteString
        self.x = Int(cue.sourceRect.origin.x.rounded())
        self.y = Int(cue.sourceRect.origin.y.rounded())
        self.width = Int(cue.sourceRect.width.rounded())
        self.height = Int(cue.sourceRect.height.rounded())
    }
}

public final class UPlayerThumbnailCache {

    public static let shared = UPlayerThumbnailCache()

    private let lock = NSLock()

    private var spriteDataCache: [String: Data] = [:]
    private var imageCache: [UPlayerThumbnailImageCacheKey: UIImage] = [:]

    private init() {}

    public func spriteData(for url: URL) -> Data? {
        lock.lock()
        defer {
            lock.unlock()
        }
        return spriteDataCache[url.absoluteString]
    }

    public func storeSpriteData(_ data: Data, for url: URL) {
        lock.lock()
        defer {
            lock.unlock()
        }
        spriteDataCache[url.absoluteString] = data
    }

    public func image(for key: UPlayerThumbnailImageCacheKey) -> UIImage? {
        lock.lock()
        defer {
            lock.unlock()
        }
        return imageCache[key]
    }

    public func storeImage(_ image: UIImage, for key: UPlayerThumbnailImageCacheKey) {
        lock.lock()
        defer {
            lock.unlock()
        }
        imageCache[key] = image
    }

    public func removeAll() {
        lock.lock()
        defer {
            lock.unlock()
        }

        spriteDataCache.removeAll()
        imageCache.removeAll()
    }
}
