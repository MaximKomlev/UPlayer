//
//  UPlayerAssetHLSData.swift
//  UPlayer
//
//  Created by Max Komleu on 2/23/26.
//

import Foundation
import AVFoundation

struct LiveHLSSegment: Hashable {
    let number: Int
    let duration: Double
    let url: String
}

struct LiveHLSPlaylistState {
    let key: String
    var initURL: String
    var targetDuration: Int
    var segments: [LiveHLSSegment]
}

public protocol UPlayerAssetHLSDataProtocol: AnyObject {
    var master: String { get set }
    var mediaPlaylists: [String: String] { get set }
    
    init(master: String, mediaPlaylists: [String: String])
}

public class UPlayerAssetHLSData: UPlayerAssetHLSDataProtocol {
    public var master: String
    public var mediaPlaylists: [String: String]
    
    public required init(master: String, mediaPlaylists: [String: String]) {
        self.master = master
        self.mediaPlaylists = mediaPlaylists
    }
}
