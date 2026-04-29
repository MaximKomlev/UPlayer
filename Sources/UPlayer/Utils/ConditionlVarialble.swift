//
//  ConditionalVariable.swift
//  UPlayer
//
//  Created by Max Komleu on 4/27/26.
//

import Foundation

internal final class ConditionalVariable {
    private let condition = NSCondition()
    private var isOnInternal: Bool = false

    var isOn: Bool {
        get {
            return isOnInternal
        } set {
            condition.lock()
            isOnInternal = newValue
            if !isOnInternal {
                condition.broadcast()
            }
            condition.unlock()
        }
    }
    
    func waitUntilOff() {
        condition.lock()
        while isOnInternal {
            condition.wait()
        }
        condition.unlock()
    }
}
