//
//  Common.swift
//  UPlayer
//
//  Created by Max Komleu on 3/10/26.
//

import Combine
import Foundation

enum DebugClock {
    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func now() -> String {
        formatter.string(from: Date())
    }
}
