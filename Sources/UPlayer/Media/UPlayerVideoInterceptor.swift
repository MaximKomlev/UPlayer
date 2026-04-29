//
//  UPlayerVideoInterceptor.swift
//  UPlayer
//
//  Created by Max Komleu on 4/28/26.
//

import Foundation
import AVFoundation

public protocol UPlayerMediaInterceptorProtocol: AnyObject {
    func initialize(with player: AVPlayer)

    func start()
    func stop()
    func attach(to: AVPlayerItem)
}

public protocol UPlayerVideoInterceptorDelegate: NSObjectProtocol {
    func willRender(source: UPlayerMediaInterceptorProtocol, frame: VideoFrameProtocol)
}

public final class UPlayerVideoInterceptor: NSObject, UPlayerMediaInterceptorProtocol {

    private var player: AVPlayer?

    private var outputs: [AVPlayerItem: AVPlayerItemVideoOutput] = [:]
    private var displayLink: CADisplayLink?

    public weak var delegate: UPlayerVideoInterceptorDelegate?

    public func initialize(with player: AVPlayer) {
        self.player = player
        observeItemChanges()
    }

    public func start() {
        displayLink = CADisplayLink(
            target: self,
            selector: #selector(readFrame)
        )
        displayLink?.add(to: .main, forMode: .common)
    }

    public func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }
    
    public func attach(to item: AVPlayerItem) {
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]

        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: settings)
        item.add(output)
        outputs[item] = output
    }

    private func observeItemChanges() {
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let item = notification.object as? AVPlayerItem else {
                return
            }
            self?.outputs[item] = nil
        }
    }
    
    @objc private func readFrame() {
        guard
            let item = player?.currentItem,
            let output = outputs[item]
        else {
            return
        }

        let hostTime = CACurrentMediaTime()
        let itemTime = output.itemTime(forHostTime: hostTime)

        guard output.hasNewPixelBuffer(forItemTime: itemTime),
              let buffer = output.copyPixelBuffer(forItemTime: itemTime,
                                                  itemTimeForDisplay: nil)
        else {
            return
        }
        
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        
        let videoFrame = VideoFrame(frame: buffer,
                                    size: CGSize(width: width, height: height),
                                    timeStamp: CMTimeGetSeconds(itemTime))
        delegate?.willRender(source: self, frame: videoFrame)
    }
}
