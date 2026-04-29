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

public class VideoFrame: VideoFrameProtocol {
    public var frame: CVPixelBuffer
    public var size: CGSize
    public var timeStamp: TimeInterval

    public init(frame: CVPixelBuffer, size: CGSize, timeStamp: TimeInterval) {
        self.frame = frame
        self.size = size
        self.timeStamp = timeStamp
    }
}

public class AudioFrame: AudioFrameProtocol {
    public var audioBufferList: AudioBufferList
    public var timeStamp: AudioTimeStamp
    public var frameCount: AUAudioFrameCount
    public var audioFormat: AVAudioFormat
    
    public init(audioBufferList: AudioBufferList, timeStamp: AudioTimeStamp, frameCount: AUAudioFrameCount, audioFormat: AVAudioFormat) {
        self.audioBufferList = audioBufferList
        self.timeStamp = timeStamp
        self.frameCount = frameCount
        self.audioFormat = audioFormat
    }
}
