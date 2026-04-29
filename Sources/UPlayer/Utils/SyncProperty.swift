//
//  SyncProperty.swift
//  UPlayer
//
//  Created by Max Komleu on 3/8/26.
//

import Foundation

internal final class Synchronizer<T: NSLocking> where T: NSObject {
    
    private let lock = T()
    
    @discardableResult public func synchronize<U>(block: () -> U) -> U {
        var result: U
        lock.lock()
        defer {
            lock.unlock()
        }
        result = block()
        return result
    }
    
}

internal final class SyncProperty<T> {
    private let lock = Synchronizer<NSLock>()
    private var syncValue: T
    
    public init(value: T) {
        syncValue = value
    }

    public var value: T {
        return lock.synchronize {
            return syncValue
        }
    }

    public func set(_ mutate: (inout T) -> Void) {
        lock.synchronize {
            mutate(&syncValue)
        }
    }
}
