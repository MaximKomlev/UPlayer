//
//  UPlayerLogger.swift
//  UPlayer
//
//  Created by Max Komleu on 4/28/26.
//

import Foundation

public enum UPlayerLoggingLevel: Int {
    case none
    case info
    case debug
    case error
}

public var onUPlayerLogging: ((String, UPlayerLoggingLevel, String, String, Int) -> ())?

internal func log(_ message: String,
                  loggingLevel: UPlayerLoggingLevel,
                  file: String = #fileID,
                  function: String = #function,
                  line: Int = #line) {
    if let onUPlayerLogging = onUPlayerLogging {
        onUPlayerLogging(message, loggingLevel, file, function, line)
        return
    }

    print("\(DebugClock.now()) - uplayer - \(message)")
}
