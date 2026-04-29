//
//  UPlayer.swift
//  UPlayer
//
//  Created by Max Komleu on 1/21/26.
//

import UIKit
import Combine
import Foundation
import AVFoundation

private let logScope = "[playback]"

public enum UPlayerPlayerState: Int, CustomStringConvertible {
    case loading
    case playing
    case paused
    case stopped
    
    public var description: String {
        switch self {
        case .loading:
            return "Loading"
        case .playing:
            return "Playing"
        case .paused:
            return "Paused"
        case .stopped:
            return "Stopped"
        }
    }
}

public class UPlayerView: UIView {
    private let playerLayer: AVPlayerLayer

    public override class var layerClass: AnyClass {
        return AVPlayerLayer.self
    }

    var player: AVPlayer? {
        get {
            return playerLayer.player
        } set {
            playerLayer.player = newValue
        }
    }
        
    // original video stream resolution
    var videoResolution = CGSize(width: 16.0, height: 9.0) {
        didSet {
            setNeedsLayout()
        }
    }

    // MARK: Constructors/Destructor

    public convenience init() {
        self.init(frame: .zero)
    }
    
    public override init(frame: CGRect) {
        playerLayer = AVPlayerLayer()
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(playerLayer)
        layer.masksToBounds = true
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: View life cycle

    public override func layoutSubviews() {
        super.layoutSubviews()
        
        let viewWidth = bounds.width
        let viewHeight = bounds.height

        let playerWidth = viewWidth
        let playerRatio = videoResolution.height / videoResolution.width
        let playerHeight = playerWidth * playerRatio
        
        let videoSize = CGSize(width: playerWidth, height: playerHeight)
        let videoPos = CGPoint(x: (viewWidth - playerWidth) / 2, y: (viewHeight - playerHeight) / 2)

        playerLayer.frame = CGRect(origin: videoPos, size: videoSize)
    }
}

public protocol UPlayerDelegate: AnyObject {

    func didEventPlayerStart(source: UPlayerProtocol)
    func didEventPlayerPlay(source: UPlayerProtocol)
    func didEventPlayerStop(source: UPlayerProtocol, error: Error?)

    func didEventPlayerChange(source: UPlayerProtocol, isPaused: Bool)
    func didEventPlayerChange(source: UPlayerProtocol, isMuted: Bool)
    func didEventPlayerChange(source: UPlayerProtocol, rate: Double)
    func didEventPlayerChange(source: UPlayerProtocol, playingTime: TimeInterval)
    func didEventPlayerChange(source: UPlayerProtocol, duration: TimeInterval)

    var playerView: UPlayerView? { get }
}

public protocol UPlayerProtocol: AnyObject {

    var state: UPlayerPlayerState { get }
    var isMuted: Bool { get set }
    var currentPlayingTime: TimeInterval { get }
    var isThumbnailsSupported: Bool { get }
    
    var avPlayer: AVPlayer { get }

    var asset: UPlayerAssetProtocol? { get }
    var assetCache: UPlayerAssetCacheProtocol? { get set }
    var assetProcessorsQueue: UPlayerAssetProcessorsQueueProtocol? { get set }

    var delegate: UPlayerDelegate? { get set }

    func play(url: URL)
    func stop()
    func pause()
    func unpause()

    func rate(_ value: Double)
    func seek(_ value: TimeInterval)
    
    func thumbnail(at time: TimeInterval) -> UIImage?
    
    func addMediaInterceptor(_ interceptor: UPlayerMediaInterceptorProtocol)
}

public class UPlayer: UPlayerProtocol {
    
    // MARK: Fields
    
    private let observer = AVPlayerObserver()
    private lazy var playerInstance: AVPlayer = {
        let player = AVPlayer()
        delegate?.playerView?.player = player
        observer.observe(player: player)
        observer.delegate = self
        return player
    }()
    
    private lazy var refreshTasks: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.uplayer.refreshTasks"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    
    private var interceptors = [UPlayerMediaInterceptorProtocol]()
    
    // MARK: Constructors/Destructor
    
    public init() {}
    
    // MARK: UPlayerProtocol
        
    public var avPlayer: AVPlayer {
        return playerInstance
    }

    public var state: UPlayerPlayerState = .stopped {
        didSet {
            if state == oldValue {
                return
            }

            log("\(logScope) player state changed: \"\(state)\"", loggingLevel: .debug)

            switch state {
            case .loading:
                delegate?.didEventPlayerStart(source: self)
            case .playing:
                if oldValue == .paused {
                    delegate?.didEventPlayerChange(source: self, isPaused: false)
                    return
                }
                delegate?.didEventPlayerPlay(source: self)
            case .paused:
                delegate?.didEventPlayerChange(source: self, isPaused: true)
            default:
                if let error = avPlayer.currentItem?.error {
                    delegate?.didEventPlayerStop(source: self, error: error)
                    return
                } else if let error = avPlayer.error {
                    delegate?.didEventPlayerStop(source: self, error: error)
                    return
                }
                delegate?.didEventPlayerStop(source: self, error: nil)
            }
        }
    }
    
    public var isMuted: Bool {
        get {
            return avPlayer.isMuted
        } set {
            if avPlayer.isMuted == newValue {
                return
            }
            avPlayer.isMuted = newValue
            delegate?.didEventPlayerChange(source: self, isMuted: newValue)
        }
    }
    
    public var currentPlayingTime: TimeInterval = 0.0 {
        didSet {
            delegate?.didEventPlayerChange(source: self, playingTime: currentPlayingTime)
        }
    }
    
    public private(set) var asset: (any UPlayerAssetProtocol)?
    
    public var assetCache: (any UPlayerAssetCacheProtocol)? = UPlayerAssetCache()
    
    public var assetProcessorsQueue: (any UPlayerAssetProcessorsQueueProtocol)? {
        didSet {
            assetProcessorsQueue?.delegate = self
        }
    }
    
    public var delegate: (any UPlayerDelegate)? {
        didSet {
            delegate?.playerView?.player = avPlayer
        }
    }
    
    public var isThumbnailsSupported: Bool {
        return asset?.thumbnailMetadata != nil
    }
    
    public func play(url: URL) {
        stop()

        state = .loading
        
        log("\(logScope) start", loggingLevel: .debug)
                
        if let asset = try? assetCache?.asset(url: url) {
            log("\(logScope) start from persistent cache", loggingLevel: .debug)
            startPlayback(asset: asset)
            startPullingLiveMpd(asset: asset)
            return
        }
        
        guard let assetProcessorsQueue else {
            let asset = UPlayerAsset(url: url)
            asset.type = .mp4
            asset.httpMetadata = UPlayerAssetHttpData(url: asset.url)
            log("\(logScope) start from url", loggingLevel: .debug)
            startPlayback(asset: asset)
            return
        }

        log("\(logScope) start loading asset", loggingLevel: .debug)
        let asset = UPlayerAsset(url: url)
        assetProcessorsQueue.start(asset: asset)
    }
    
    public func stop() {
        log("\(logScope) stop", loggingLevel: .debug)

        refreshTasks.cancelAllOperations()
        asset = nil
        assetProcessorsQueue?.stop()
        avPlayer.currentItem?.cancelPendingSeeks()
        avPlayer.currentItem?.asset.cancelLoading()
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: nil)
        state = .stopped
    }
    
    public func pause() {
        avPlayer.pause()
    }
    
    public func unpause() {
        avPlayer.play()
    }
    
    public func rate(_ value: Double) {
        avPlayer.rate = Float(exactly: value) ?? 1.0
    }
    
    public func seek(_ value: TimeInterval) {
        let time = CMTime(seconds: Double(value), preferredTimescale: 1)
        avPlayer.seek(to: time)
    }
    
    public func thumbnail(at time: TimeInterval) -> UIImage? {
        if let cue = asset?.thumbnailMetadata?.cue(for: time),
           let image = asset?.thumbnailMetadata?.image(for: cue) {
            return image
        }
        return nil
    }
    
    public func addMediaInterceptor(_ interceptor: UPlayerMediaInterceptorProtocol) {
        if interceptors.contains(where: { listed in
            return interceptor === listed
        }) {
            return
        }
        
        interceptors.append(interceptor)
        interceptor.initialize(with: avPlayer)
    }
    
    // MARK: Helpers
    
    private func startPlayback(asset: UPlayerAssetProtocol) {
        log("\(logScope) ready to play", loggingLevel: .debug)
        Task {
            do {
                self.asset = asset
                
                let item = try await makePlayerItem(from: asset)
                log("\(logScope) replacing AVPlayerItem", loggingLevel: .debug)
                avPlayer.replaceCurrentItem(with: item)
                interceptors.forEach { listed in
                    listed.attach(to: item)
                }

                if state != .loading && state != .playing {
                    log("\(logScope) started", loggingLevel: .debug)
                    avPlayer.play()
                }
            } catch {
                log("\(logScope) failed, \(error)", loggingLevel: .error)
            }
        }
    }
    
    private func startPullingLiveMpd(asset: UPlayerAssetProtocol) {
        switch asset.type {
        case .mpd:
            if asset.mpdMetadata?.manifest?.type != .dynamicLive {
                return
            }
            
            let operation = BlockOperation()
            operation.addExecutionBlock { [weak self, weak operation] in
                guard let self, let operation else {
                    return
                }

                log("\(logScope) start pulling live MPD", loggingLevel: .debug)

                while !operation.isCancelled {
                    self.assetProcessorsQueue?.start(asset: asset)
                    let delay = self.nextRefreshDelay(asset: asset)
                    Thread.sleep(forTimeInterval: delay)
                }
                
                self.assetCache?.removeAsset(asset)
                log("\(logScope) stopped pulling live MPD", loggingLevel: .debug)
            }
            refreshTasks.addOperation(operation)

        default:
            break
        }
    }
    
    private func nextRefreshDelay(asset: UPlayerAssetProtocol) -> TimeInterval {
        var seconds: TimeInterval = 3

        if let manifest = asset.mpdMetadata?.manifest,
           let mup = manifest.minimumUpdatePeriod,
           mup > 0 {
            seconds = mup
        }

        return TimeInterval(seconds)
    }
    
}

extension UPlayer: UPlayerAssetProcessorsQueueDelegate {
    public func didStartProcessing(source: any UPlayerAssetProcessorsQueueProtocol) {
    }
    
    public func didFinishProcessing(source: any UPlayerAssetProcessorsQueueProtocol, error: (any Error)?) {
    }
    
    public func didFinishProcessing(source: any UPlayerAssetProcessorsQueueProtocol, asset: any UPlayerAssetProtocol) {
        log("\(logScope) processing finished", loggingLevel: .debug)

        if let existingAsset = self.asset {
            // Live refresh path: update existing asset metadata only
            existingAsset.type = asset.type
            existingAsset.httpMetadata = asset.httpMetadata
            existingAsset.mpdMetadata = asset.mpdMetadata
            mergeLiveHLS(
                existing: existingAsset.hlsMetadata,
                incoming: asset.hlsMetadata
            )
            log("\(logScope) live refresh updated playlists only", loggingLevel: .debug)
            return
        }

        assetCache?.addAsset(asset)

        startPlayback(asset: asset)
        startPullingLiveMpd(asset: asset)
    }
    
    private func makePlayerItem(from asset: any UPlayerAssetProtocol) async throws -> AVPlayerItem {
        var isPlayable = false
        var avAsset: AVURLAsset
        
        switch asset.type {
        case .hls, .mp4:
            guard let url = asset.httpMetadata?.url else {
                throw UPlayerErrorsList.invalidAssetURL
            }
            avAsset = AVURLAsset(url: url)
            isPlayable = true
            break
        case .mpd:
            guard let url = modifyURLScheme(asset.url) else {
                throw UPlayerErrorsList.invalidAssetURL
            }
            
            guard let url = convertToUPlayerHLSURL(url) else {
                throw UPlayerErrorsList.invalidAssetURL
            }
            avAsset = AVURLAsset(url: url)

            let loader = UPlayerAVAssetResourceLoader()
            asset.addAssetLoader(loader)

            avAsset.resourceLoader.setDelegate(loader, queue: DispatchQueue(label: "resource.loader.queue"))

            isPlayable = try await avAsset.load(.isPlayable)
        default:
            throw UPlayerErrorsList.invalidAssetURL
        }
        
        
        guard isPlayable else {
            throw UPlayerErrorsList.invalidAsset
        }
                
        return AVPlayerItem(asset: avAsset)
    }
}

extension UPlayer: AVPlayerObserverDelegate {
    func player(_ player: AVPlayer, didChangeState state: UPlayerPlayerState) {
        DispatchQueue.main.async {
            self.state = state
        }
    }
    
    func player(_ player: AVPlayer, didChangeCurrentTime currentTime: TimeInterval) {
        DispatchQueue.main.async {
            self.currentPlayingTime = currentTime
        }
    }
    
    func player(_ player: AVPlayer, didChangeDuration duration: TimeInterval) {
        DispatchQueue.main.async {
            self.asset?.duration = duration
            self.delegate?.didEventPlayerChange(source: self, duration: duration)
        }
    }
    
    func player(_ player: AVPlayer, didChangeResolution resolution: CGSize) {
        DispatchQueue.main.async {
            self.asset?.videoRatio = resolution.height / resolution.width
            self.delegate?.playerView?.videoResolution = resolution
        }
    }
    
    func player(_ player: AVPlayer, didChangeRate rate: Double) {
        DispatchQueue.main.async {
            self.delegate?.didEventPlayerChange(source: self, rate: rate)
        }
    }
}
