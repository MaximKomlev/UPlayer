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

public enum UPlayerMediaInterceptorType: Int, CustomStringConvertible {
    case video
    case audio
    
    public var description: String {
        switch self {
        case .video:
            return "video"
        case .audio:
            return "audio"
        }
    }
}

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

open class UPlayerView: UIView {

    private let playerLayer: AVPlayerLayer
    private let placeholderImageView = UIImageView()
    private var readyForDisplayObservation: NSKeyValueObservation?

    public override class var layerClass: AnyClass {
        return AVPlayerLayer.self
    }

    var player: AVPlayer? {
        get {
            return playerLayer.player
        } set {
            showPlaceholder()
            playerLayer.player = newValue
        }
    }

    // Original video stream resolution
    var videoResolution = CGSize(width: 16.0, height: 9.0) {
        didSet {
            setNeedsLayout()
        }
    }

    public var placeholderImage: UIImage? {
        get {
            return placeholderImageView.image
        } set {
            placeholderImageView.image = newValue

            if newValue == nil {
                placeholderImageView.isHidden = true
            }
        }
    }

    public var placeholderContentMode: UIView.ContentMode {
        get {
            return placeholderImageView.contentMode
        } set {
            placeholderImageView.contentMode = newValue
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

        setupPlaceholder()
        observePlayerLayer()
    }

    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        readyForDisplayObservation?.invalidate()
    }

    // MARK: View life cycle

    open override func layoutSubviews() {
        super.layoutSubviews()
        
        let viewWidth = bounds.width
        let viewHeight = bounds.height
        
        guard videoResolution.width > 0,
              videoResolution.height > 0,
              bounds.width > 0,
              bounds.height > 0 else {
            return
        }
        
        let widthScale = bounds.width / videoResolution.width
        let heightScale = bounds.height / videoResolution.height
        let scale = min(widthScale, heightScale)
        
        let videoSize = CGSize(width: videoResolution.width * scale,
                               height: videoResolution.height * scale)
        
        let videoOrigin = CGPoint(x: (bounds.width - videoSize.width) / 2,
                                  y: (bounds.height - videoSize.height) / 2)
        
        let videoFrame = CGRect(origin: videoOrigin, size: videoSize)
        
        playerLayer.frame = videoFrame
        placeholderImageView.bounds = CGRect(origin: .zero, size: videoSize)
        placeholderImageView.center = CGPoint(x: viewWidth / 2, y: viewHeight / 2)
    }

    // MARK: Placeholder

    public func showPlaceholder() {
        guard placeholderImageView.image != nil else {
            return
        }

        placeholderImageView.isHidden = false
    }

    public func hidePlaceholder(animated: Bool = true) {
        guard animated else {
            placeholderImageView.isHidden = true
            return
        }

        UIView.animate(withDuration: 0.2,
                       animations: {
            self.placeholderImageView.alpha = 0
        },
                       completion: { _ in
            self.placeholderImageView.isHidden = true
            self.placeholderImageView.alpha = 1
        })
    }
}

private extension UPlayerView {

    func setupPlaceholder() {
        placeholderImageView.contentMode = .scaleAspectFill
        placeholderImageView.clipsToBounds = true
        placeholderImageView.isUserInteractionEnabled = false
        placeholderImageView.isHidden = true

        addSubview(placeholderImageView)
    }

    func observePlayerLayer() {
        readyForDisplayObservation = playerLayer.observe(\.isReadyForDisplay,
                                                          options: [.initial, .new]) { [weak self] layer, _ in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }

                if layer.isReadyForDisplay {
                    self.hidePlaceholder()
                }
            }
        }
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
    var rate: Double { get set }
    var currentPlayingTime: TimeInterval { get }
    var isThumbnailsSupported: Bool { get }
    
    var avPlayer: AVPlayer { get }

    var asset: UPlayerAssetProtocol? { get }
    var assetCache: UPlayerAssetCacheProtocol? { get set }
    var assetProcessorsQueue: UPlayerAssetProcessorsQueueProtocol? { get set }

    var delegate: UPlayerDelegate? { get set }

    func attachPlayerView(_ view: UPlayerView?)

    func play(url: URL)
    func stop()
    func pause()
    func unpause()
    func restart()
    
    func seek(_ value: TimeInterval)
    func seek(_ value: TimeInterval, completionHandler: ((Bool) -> ())?)
    
    func thumbnail(at time: TimeInterval) -> UIImage?
    
    func registerMediaInterceptor(_ interceptor: UPlayerMediaInterceptorProtocol, type: UPlayerMediaInterceptorType)
    func registerAudioTranscoder(_ transcoder: UPlayerAudioTranscoderProtocol, forCodec type: UPlayerSupportedAudioCodecType)
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
    
    private var interceptors = [UPlayerMediaInterceptorType: UPlayerMediaInterceptorProtocol]()
    private let audioTranscoders = UPlayerAudioTranscoderFactory()
    
    private var playbackRate: Float = 1.0
    
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
                DispatchQueue.main.async {
                    self.delegate?.didEventPlayerStart(source: self)
                }
            case .playing:
                if oldValue == .paused {
                    DispatchQueue.main.async {
                        self.delegate?.didEventPlayerChange(source: self, isPaused: false)
                    }
                    return
                }
                DispatchQueue.main.async {
                    self.delegate?.didEventPlayerPlay(source: self)
                }
            case .paused:
                DispatchQueue.main.async {
                    self.delegate?.didEventPlayerChange(source: self, isPaused: true)
                }
            default:
                if let error = avPlayer.currentItem?.error {
                    DispatchQueue.main.async {
                        self.delegate?.didEventPlayerStop(source: self, error: error)
                    }
                    return
                } else if let error = avPlayer.error {
                    DispatchQueue.main.async {
                        self.delegate?.didEventPlayerStop(source: self, error: error)
                    }
                    return
                }
                DispatchQueue.main.async {
                    self.delegate?.didEventPlayerStop(source: self, error: nil)
                }
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
            DispatchQueue.main.async {
                self.delegate?.didEventPlayerChange(source: self, isMuted: newValue)
            }
        }
    }
    
    public var rate: Double {
        get {
            return Double(playbackRate)
        }
        set {
            playbackRate = Float(newValue)

            if avPlayer.rate != 0 {
                avPlayer.rate = playbackRate
            }
        }
    }
    
    public var currentPlayingTime: TimeInterval = 0.0 {
        didSet {
            DispatchQueue.main.async {
                self.delegate?.didEventPlayerChange(source: self, playingTime: self.currentPlayingTime)
            }
        }
    }
    
    public private(set) var asset: (any UPlayerAssetProtocol)?
    
    public var assetCache: (any UPlayerAssetCacheProtocol)? = UPlayerAssetCache()
    
    public var assetProcessorsQueue: (any UPlayerAssetProcessorsQueueProtocol)? {
        didSet {
            assetProcessorsQueue?.delegate = self
        }
    }
    
    public weak var delegate: (any UPlayerDelegate)? {
        didSet {
            attachPlayerView(delegate?.playerView)
        }
    }
    
    public var isThumbnailsSupported: Bool {
        return asset?.thumbnailMetadata != nil
    }
    
    public func attachPlayerView(_ view: UPlayerView?) {
        view?.player = avPlayer
    }
    
    public func play(url: URL) {
        stop()

        delegate?.playerView?.showPlaceholder()

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

        delegate?.playerView?.showPlaceholder()

        state = .stopped
    }
    
    public func pause() {
        avPlayer.pause()
    }
    
    public func unpause() {
        avPlayer.playImmediately(atRate: playbackRate)
    }
        
    public func restart() {
        avPlayer.pause()

        avPlayer.seek(
            to: .zero,
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] finished in
            guard let self,
                  finished else {
                return
            }

            self.avPlayer.playImmediately(atRate: self.playbackRate)
        }
    }
    
    public func seek(_ value: TimeInterval) {
        let time = CMTime(seconds: Double(value), preferredTimescale: 1)
        avPlayer.seek(to: time)
    }

    public func seek(_ value: TimeInterval, completionHandler: ((Bool) -> ())?) {
        let time = CMTime(seconds: Double(value), preferredTimescale: 1)
        avPlayer.seek(to: time) { state in
            completionHandler?(state)
        }
    }

    public func thumbnail(at time: TimeInterval) -> UIImage? {
        if let cue = asset?.thumbnailMetadata?.cue(for: time),
           let image = asset?.thumbnailMetadata?.image(for: cue) {
            return image
        }
        return nil
    }
    
    public func registerMediaInterceptor(_ interceptor: UPlayerMediaInterceptorProtocol, type: UPlayerMediaInterceptorType) {
        interceptors[type] = interceptor
        interceptor.initialize(with: avPlayer)
    }
    
    public func registerAudioTranscoder(_ transcoder: UPlayerAudioTranscoderProtocol, forCodec type: UPlayerSupportedAudioCodecType) {
        audioTranscoders.registerTranscoder(transcoder, forCodec: type)
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
                interceptors.forEach { _, listed in
                    listed.attach(to: item)
                }

                if state != .playing {
                    log("\(logScope) started with rate: \(playbackRate)", loggingLevel: .debug)
                    avPlayer.playImmediately(atRate: playbackRate)
                }
            } catch {
                log("\(logScope) failed, \(error)", loggingLevel: .error)
            }
        }
    }
    
    private func startPullingLiveMpd(asset: UPlayerAssetProtocol) {
        switch asset.type {
        case .mpd:
            if asset.mpdMetadata?.manifestType != .dynamicLive {
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
            loader.transcoderDelegate = self
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

extension UPlayer: UPlayerAVAssetResourceLoaderTranscodingDelegate {
    public func getAudioTranscoder(source: any UPlayerAVAssetResourceLoaderProtocol) -> (any UPlayerAudioTranscoderProtocol)? {
        return audioTranscoders
    }
}
