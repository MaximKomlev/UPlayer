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

internal func modifyURLScheme(_ url: URL, newScheme: String = "uplayer") -> URL? {
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    
    // Replace scheme
    components?.scheme = newScheme
    
    guard let newURL = components?.url else { return nil }
    
    // Remove filename
    return newURL
}

internal func convertToUPlayerHLSURL(_ url: URL) -> URL? {
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    components?.scheme = "uplayer"

    guard let newURL = components?.url else { return nil }

    return newURL
        .deletingPathExtension()
        .appendingPathExtension("m3u8")
}
