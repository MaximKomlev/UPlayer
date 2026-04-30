//
//  ProcessorsUtils.swift
//  UPlayer
//
//  Created by Max Komleu on 4/29/26.
//

import Foundation

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

internal func normalizeMP4ACodec(_ codec: String?) -> String? {
    guard let codec = codec?.lowercased() else { return nil }

    let parts = codec.split(separator: ".")
    guard parts.count == 3,
          parts[0] == "mp4a",
          parts[1] == "40" else {
        return codec
    }

    // Normalize object type (remove leading zeros)
    if let objectType = Int(parts[2]) {
        return "mp4a.40.\(objectType)"
    }

    return codec
}

internal func mergeLiveHLS(existing: UPlayerAssetHLSDataProtocol?, incoming: UPlayerAssetHLSDataProtocol?) {
    guard let existing, let incoming else {
        return
    }

    existing.master = incoming.master

    for (key, newPlaylist) in incoming.mediaPlaylists {
        existing.mediaPlaylists[key] = newPlaylist
    }
}
