//
//  UPlayerURLScheme.swift
//  UPlayer
//
//  Shared helpers for the `uplayer://` custom scheme used to route
//  manifest/audio/video requests through `UPlayerAVAssetResourceLoader`.
//  Extracted so both the resource loader and `UPlayerWarmPathSession` agree
//  on exactly how to recover the original `https://` URL — they must,
//  since that recovered URL is the cache key `UPlayerFragmentCache` uses,
//  and a prefetch that doesn't key identically to a live request is a
//  silent cache miss.
//

import Foundation

enum UPlayerURLScheme {

    /// The `mode=` query item value on a rewritten `uplayer://` URL, e.g.
    /// `"video-segment"`, `"video-init"`, `"audio-transcode"`,
    /// `"audio-transcode-init"`.
    static func mode(of url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first {
            $0.name == "mode"
        }?.value
    }

    static func codec(from url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first {
            $0.name == "codec"
        }?.value
    }

    /// Recovers the original `https://` URL from a `uplayer://`-rewritten
    /// URL, stripping the `mode`/`codec` query items that were added on
    /// rewrite.
    static func originalHTTPURL(from url: URL) -> URL? {
        let original = url.absoluteString
        guard let schemeRange = original.range(of: "://") else {
            return nil
        }

        let value = "https://" + original[schemeRange.upperBound...]
        guard let questionMark = value.firstIndex(of: "?") else {
            return URL(string: value)
        }

        let base = String(value[..<questionMark])
        let queryStart = value.index(after: questionMark)
        let rawQuery = String(value[queryStart...])

        let filteredQuery = rawQuery.split(separator: "&", omittingEmptySubsequences: false).filter { rawItem in
            let name = rawItem.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            return name != "mode" && name != "codec"
        }.joined(separator: "&")

        let result = filteredQuery.isEmpty ? base : "\(base)?\(filteredQuery)"
        return URL(string: result)
    }
}
