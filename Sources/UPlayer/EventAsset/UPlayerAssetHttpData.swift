//
//  UPlayerAssetHttpData.swift
//  UPlayer
//
//  Created by Max Komleu on 2/23/26.
//

import Foundation
import AVFoundation

public protocol UPlayerAssetHttpDataProtocol: AnyObject {
    var url: URL { get }

    init(url: URL)
}

public class UPlayerAssetHttpData: UPlayerAssetHttpDataProtocol {
    public var url: URL

    public required init(url: URL) {
        self.url = url
    }
}
