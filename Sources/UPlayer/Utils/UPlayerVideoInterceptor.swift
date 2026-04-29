//
//  UPlayerVideoInterceptor.swift
//  UPlayer
//
//  Created by Max Komleu on 4/28/26.
//

import Foundation
import AVFoundation

public protocol UPlayerVideoInterceptorDelegate: NSObjectProtocol {
    func willRender(pixelBuffer: CVPixelBuffer, on time: CMTime)
}

public protocol UPlayerInterceptorProtocol: AnyObject {
    var delegate: UPlayerVideoInterceptorDelegate? { get set }
    
    init(player: AVPlayer)

    func start()
    func stop()
    func attach(to: AVPlayerItem)
}

public final class UPlayerVideoInterceptor: NSObject, UPlayerInterceptorProtocol {

    private let player: AVPlayer

    private var outputs: [AVPlayerItem: AVPlayerItemVideoOutput] = [:]
    private var displayLink: CADisplayLink?

    public required init(player: AVPlayer) {
        self.player = player
        
        super.init()
        
        observeItemChanges()
    }

    public weak var delegate: UPlayerVideoInterceptorDelegate?
    
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
            guard let item = notification.object as? AVPlayerItem else { return }
            self?.outputs[item] = nil
        }
    }
    
    @objc private func readFrame() {
        guard
            let item = player.currentItem,
            let output = outputs[item]
        else {
            return
        }

        let hostTime = CACurrentMediaTime()
        let itemTime = output.itemTime(forHostTime: hostTime)

        guard output.hasNewPixelBuffer(forItemTime: itemTime),
              let buffer = output.copyPixelBuffer(
                forItemTime: itemTime,
                itemTimeForDisplay: nil
              )
        else {
            return
        }

        delegate?.willRender(pixelBuffer: buffer, on: itemTime)
    }
}
