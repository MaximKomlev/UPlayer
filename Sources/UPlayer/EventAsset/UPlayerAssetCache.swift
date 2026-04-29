//
//  UPlayerAssetCache.swift
//  UPlayer
//
//  Created by Max Komleu on 2/23/26.
//

import Foundation

public protocol UPlayerAssetCacheProtocol: AnyObject {
    func addAsset(_ asset: UPlayerAssetProtocol)
    func removeAsset(_ asset: UPlayerAssetProtocol)
    func asset(url: URL) throws -> UPlayerAssetProtocol
}

public class UPlayerAssetCache: UPlayerAssetCacheProtocol {
    
    // MARK: Fields
    
    private var assets: [AnyHashable: UPlayerAssetProtocol] = [:]
    private let lock = NSLock()
    
    // MARK: UPlayerAssetCacheProtocol
    
    public func addAsset(_ asset: UPlayerAssetProtocol) {
        lock.lock()
        defer {
            lock.unlock()
        }

        if let _ = assets[asset.url] {
            return
        }
        
        assets[asset.url] = asset
    }
    
    public func removeAsset(_ asset: UPlayerAssetProtocol) {
        lock.lock()
        defer {
            lock.unlock()
        }

        guard let _ = assets[asset.url] else {
            return
        }
        
        assets.removeValue(forKey: asset.url)
    }

    public func asset(url: URL) throws -> UPlayerAssetProtocol {
        lock.lock()
        defer {
            lock.unlock()
        }

        guard let asset = assets[url] else {
            throw UPlayerErrorsList.assetNotFoundError
        }
        
        return asset
    }
}
