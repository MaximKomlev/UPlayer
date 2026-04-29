//
//  MediaFrame.swift
//  UPlayer
//
//  Created by Max Komleu on 3/9/26.
//

import Foundation
import AVFoundation

public protocol MediaFrameProtocol: AnyObject {
    
}

public protocol VideoFrameProtocol: MediaFrameProtocol {
    var frame: CVPixelBuffer { get }
    var size: CGSize { get }
    var timeStamp: TimeInterval { get }
}

public protocol AudioFrameProtocol: MediaFrameProtocol {
    var audioBufferList: AudioBufferList { get }
    var timeStamp: AudioTimeStamp { get }
    var frameCount: AUAudioFrameCount { get }
    var audioFormat: AVAudioFormat { get }
}
