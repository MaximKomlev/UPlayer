//
//  AVPlayerObserver.swift
//  UPlayer
//
//  Created by Max Komleu on 3/10/26.
//

import AVFoundation
import CoreGraphics

private let logScope = "[playback]"

internal protocol AVPlayerObserverDelegate: AnyObject {
    func player(_ player: AVPlayer, didChangeState state: UPlayerPlayerState)
    func player(_ player: AVPlayer, didChangeCurrentTime currentTime: TimeInterval)
    func player(_ player: AVPlayer, didChangeDuration duration: TimeInterval)
    func player(_ player: AVPlayer, didChangeResolution resolution: CGSize)
    func player(_ player: AVPlayer, didChangeRate rate: Double)
}

internal final class AVPlayerObserver: NSObject {

    private weak var item: AVPlayerItem?
    private weak var player: AVPlayer?

    private var itemErrorObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var itemDurationObservation: NSKeyValueObservation?
    private var itemPresentationSizeObservation: NSKeyValueObservation?

    private var playerRateObservation: NSKeyValueObservation?
    private var playerErrorObservation: NSKeyValueObservation?
    private var playerTimeControlObservation: NSKeyValueObservation?
    private var playerCurrentItemObservation: NSKeyValueObservation?

    private var periodicTimeObserver: Any?

    weak var delegate: AVPlayerObserverDelegate?

    func observe(player: AVPlayer) {
        self.player = player

        // Observe player.error
        playerErrorObservation = player.observe(\.error, options: [.initial, .new]) { player, _ in
            if let error = player.error {
                Self.printFullError(error, prefix: "player error")
            }
        }

        playerRateObservation = player.observe(\.rate, options: [.initial, .new]) { [weak self] player, change in
            guard let self else {
                return
            }
            self.delegate?.player(player, didChangeRate: Double(change.newValue ?? 1))
        }

        // Observe player.timeControlStatus
        playerTimeControlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            guard let self else {
                return
            }

            switch player.timeControlStatus {
            case .paused:
                self.delegate?.player(player, didChangeState: .paused)
                log("\(logScope) timeControlStatus: paused", loggingLevel: .info)

            case .waitingToPlayAtSpecifiedRate:
                self.delegate?.player(player, didChangeState: .loading)
                log("\(logScope) timeControlStatus: waiting", loggingLevel: .info)
                if let reason = player.reasonForWaitingToPlay {
                    log("\(logScope) waiting reason: \(reason.rawValue)", loggingLevel: .debug)
                }

            case .playing:
                self.delegate?.player(player, didChangeState: .playing)
                log("\(logScope) timeControlStatus: playing", loggingLevel: .info)

            @unknown default:
                log("\(logScope) timeControlStatus: unknown", loggingLevel: .info)
            }
        }

        // Observe player.currentItem changes
        playerCurrentItemObservation = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] player, _ in
            guard let self else {
                return
            }

            if let currentItem = player.currentItem {
                log("\(logScope) currentItem changed", loggingLevel: .info)
                self.observe(item: currentItem)
            } else {
                log("\(logScope) currentItem is nil", loggingLevel: .info)
                self.clearItemObservers()
            }
        }

        // Periodic current time observer
        addPeriodicTimeObserver(to: player)

        // Observe current item immediately if present
        if let currentItem = player.currentItem {
            observe(item: currentItem)
        }
    }

    func observe(item: AVPlayerItem) {
        clearItemObservers()
        self.item = item

        // Observe item.status
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { item, _ in
            switch item.status {
            case .readyToPlay:
                log("\(logScope) item status: readyToPlay", loggingLevel: .info)

            case .failed:
                log("\(logScope) item status: failed", loggingLevel: .error)
                if let error = item.error {
                    Self.printFullError(error, prefix: "\(logScope) item failed")
                } else {
                    log("\(logScope) item failed: unknown error", loggingLevel: .error)
                }

            case .unknown:
                log("\(logScope) item status: unknown", loggingLevel: .info)

            @unknown default:
                log("\(logScope) item status: unknown default", loggingLevel: .info)
            }
        }

        // Observe item.error
        itemErrorObservation = item.observe(\.error, options: [.initial, .new]) { item, _ in
            if let error = item.error {
                Self.printFullError(error, prefix: "\(logScope) item failed")
            }
        }

        // Observe item.duration
        itemDurationObservation = item.observe(\.duration, options: [.initial, .new]) { [weak self] item, _ in
            guard
                let self,
                let player = self.player
            else { return }

            let seconds = CMTimeGetSeconds(item.duration)
            guard seconds.isFinite, !seconds.isNaN, seconds >= 0 else {
                return
            }

            self.delegate?.player(player, didChangeDuration: seconds)
            log("\(logScope) duration changed: \(seconds)", loggingLevel: .info)
        }

        // Observe item.presentationSize
        itemPresentationSizeObservation = item.observe(\.presentationSize, options: [.initial, .new]) { [weak self] item, _ in
            guard
                let self,
                let player = self.player
            else { return }

            let size = item.presentationSize
            guard size.width > 0, size.height > 0 else {
                return
            }

            self.delegate?.player(player, didChangeResolution: size)
            log("\(logScope) resolution changed: \(size)", loggingLevel: .info)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playFailed(_:)),
            name: .AVPlayerItemFailedToPlayToEndTime,
            object: item
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playbackStalled(_:)),
            name: .AVPlayerItemPlaybackStalled,
            object: item
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(itemDidPlayToEnd(_:)),
            name: .AVPlayerItemDidPlayToEndTime,
            object: item
        )
    }

    private func addPeriodicTimeObserver(to player: AVPlayer) {
        removePeriodicTimeObserver()

        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)

        periodicTimeObserver = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self, weak player] time in
            guard
                let self,
                let player
            else { return }

            let seconds = CMTimeGetSeconds(time)
            guard seconds.isFinite, !seconds.isNaN else {
                return
            }

            self.delegate?.player(player, didChangeCurrentTime: seconds)
        }
    }

    private func removePeriodicTimeObserver() {
        if let periodicTimeObserver, let player {
            player.removeTimeObserver(periodicTimeObserver)
            self.periodicTimeObserver = nil
        }
    }

    @objc private func playFailed(_ notification: Notification) {
        log("\(logScope) notification: AVPlayerItemFailedToPlayToEndTime", loggingLevel: .info)

        if let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
            Self.printFullError(error, prefix: "failed to play to end")
        }
    }

    @objc private func playbackStalled(_ notification: Notification) {
        log("\(logScope) notification: AVPlayerItemPlaybackStalled", loggingLevel: .info)
    }

    @objc private func itemDidPlayToEnd(_ notification: Notification) {
        log("\(logScope) notification: AVPlayerItemDidPlayToEndTime", loggingLevel: .info)

        if let player {
            delegate?.player(player, didChangeState: .paused)
        }
    }

    private func clearItemObservers() {
        if let item {
            NotificationCenter.default.removeObserver(
                self,
                name: .AVPlayerItemFailedToPlayToEndTime,
                object: item
            )
            NotificationCenter.default.removeObserver(
                self,
                name: .AVPlayerItemPlaybackStalled,
                object: item
            )
            NotificationCenter.default.removeObserver(
                self,
                name: .AVPlayerItemDidPlayToEndTime,
                object: item
            )
        }

        itemStatusObservation = nil
        itemErrorObservation = nil
        itemDurationObservation = nil
        itemPresentationSizeObservation = nil
        item = nil
    }

    deinit {
        clearItemObservers()
        removePeriodicTimeObserver()
        NotificationCenter.default.removeObserver(self)

        playerRateObservation = nil
        playerErrorObservation = nil
        playerTimeControlObservation = nil
        playerCurrentItemObservation = nil
    }

    static func printFullError(_ error: Error, prefix: String) {
        let nsError = error as NSError

        log("\(prefix): \(nsError.localizedDescription)", loggingLevel: .error)
        log("\(prefix), domain: \(nsError.domain)", loggingLevel: .error)
        log("\(prefix), code: \(nsError.code)", loggingLevel: .error)

        if let failureReason = nsError.userInfo[NSLocalizedFailureReasonErrorKey] {
            log("\(prefix), failure reason: \(failureReason)", loggingLevel: .error)
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] {
            log("\(prefix) underlying: \(underlying)", loggingLevel: .error)
        }

        if let dependencies = nsError.userInfo["AVErrorFailedDependenciesKey"] {
            log("\(prefix), dependencies: \(dependencies)", loggingLevel: .error)
        }
    }
}
