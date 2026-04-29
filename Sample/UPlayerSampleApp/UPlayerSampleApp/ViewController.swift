//
//  ViewController.swift
//  UPlayer
//
//  Created by Max Komleu on 3/8/26.
//

import UIKit
import AVKit
import UPlayer
import AVFoundation

class ViewController: UIViewController {
    
    private let playerViewController = AVPlayerViewController()
    private let player = UPlayer()
    private let customScrubber = UISlider()
    private var isScrubbing: Bool = false
    private let preview = UIImageView()

    override func viewDidLoad() {
        super.viewDidLoad()
        
        title = "UPlayer"
                
        let rightBarButtonItem = UIBarButtonItem(title: "Video List", style: .plain, target: self, action: #selector(rightNavBarButtonAction))
        navigationItem.rightBarButtonItem = rightBarButtonItem

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Audio session error: \(error)")
        }
        
        preview.backgroundColor = .clear
        preview.contentMode = .scaleAspectFit
        preview.bounds = CGRect(origin: .zero, size: CGSize(width: 90, height: 50.625))
        preview.isHidden = true
        preview.layer.cornerRadius = 2

        customScrubber.isHidden = true
        customScrubber.minimumValue = 0
        customScrubber.maximumValue = 0
        customScrubber.translatesAutoresizingMaskIntoConstraints = false
        customScrubber.addTarget(self, action: #selector(scrubberChanged(_:)), for: .valueChanged)
        customScrubber.addTarget(self, action: #selector(scrubberTouchDown(_:)), for: .touchDown)
        customScrubber.addTarget(self, action: #selector(scrubberTouchUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])

        playerViewController.showsPlaybackControls = true
        playerViewController.allowsPictureInPicturePlayback = true
        playerViewController.canStartPictureInPictureAutomaticallyFromInline = true
        playerViewController.player = player.avPlayer
        playerViewController.contentOverlayView?.addSubview(customScrubber)
        playerViewController.contentOverlayView?.addSubview(preview)
        addChild(playerViewController)
        view.addSubview(playerViewController.view)
        playerViewController.didMove(toParent: self)
        playerViewController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            playerViewController.view.topAnchor.constraint(equalTo: view.topAnchor),
            playerViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            playerViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            playerViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        
        if let contentOverlayView = playerViewController.contentOverlayView {
            NSLayoutConstraint.activate([
                customScrubber.centerXAnchor.constraint(equalTo: contentOverlayView.centerXAnchor),
                customScrubber.bottomAnchor.constraint(equalTo: contentOverlayView.safeAreaLayoutGuide.bottomAnchor, constant: -60),
                customScrubber.widthAnchor.constraint(equalTo: contentOverlayView.widthAnchor, constant: -30),
                customScrubber.heightAnchor.constraint(equalToConstant: 32)
            ])
        }
        
        view.setNeedsLayout()

        player.registerAudioTranscoder(UPlayerG711ToAACTranscoder(), forCodec: .g711)
        player.assetProcessorsQueue = UPlayerAssetProcessorsQueue()
        player.delegate = self

        player.assetProcessorsQueue?.add(processor: UPlayerMetadataDownloader(id: "downloadAssetProcessor"))
        player.assetProcessorsQueue?.add(processor: UPlayerMPDParser(id: "mpdParserAssetProcessor"))
        player.assetProcessorsQueue?.add(processor: UPlayerThumbnailDownloader(id: "thumbnailDownloaderProcessor"))
        player.assetProcessorsQueue?.add(processor: UPlayerSegmentBaseHLSGenerator(id: "hlsSegmentBaseAssetProcessor"))
        player.assetProcessorsQueue?.add(processor: UPlayerMPDToMP4Resolver(id: "MPDToMP4ResolverAssetProcessor"))
        player.assetProcessorsQueue?.add(processor: UPlayerHLSGenerator(id: "hlsGeneratorAssetProcessor"))
    }
            
    @objc private func rightNavBarButtonAction(sender: UIBarButtonItem) {
        let alert = UIAlertController(title: "Video list", message: "Please chose video to play", preferredStyle: .actionSheet)
        
        alert.addAction(UIAlertAction(title: "Live", style: .default , handler:{ (UIAlertAction)in
            guard let url = URL(string: "https://livesim.dashif.org/livesim/testpic_2s/Manifest.mpd") else {
                return
            }
            self.player.play(url: url)
        }))

        alert.addAction(UIAlertAction(title: "MPD with preview", style: .default , handler:{ (UIAlertAction)in
            guard let url = URL(string: "https://dash.akamaized.net/akamai/bbb_30fps/bbb_with_multiple_tiled_thumbnails.mpd") else {
                return
            }
            self.player.play(url: url)
        }))

        alert.addAction(UIAlertAction(title: "Segment template MPD", style: .default , handler:{ (UIAlertAction)in
            guard let url = URL(string: "https://ftp.itec.aau.at/datasets/DASHDataset2014/BigBuckBunny/15sec/BigBuckBunny_15s_simple_2014_05_09.mpd") else {
                return
            }
            self.player.play(url: url)
        }))
        
        alert.addAction(UIAlertAction(title: "Segment base MPD", style: .default , handler:{ (UIAlertAction)in
            guard let url = URL(string: "https://ftp.itec.aau.at/datasets/DASHDataset2014/BigBuckBunny/15sec/BigBuckBunny_15s_onDemand_2014_05_09.mpd") else {
                return
            }
            self.player.play(url: url)
        }))

        alert.addAction(UIAlertAction(title: "Segment template MPD with Audio", style: .default , handler:{ (UIAlertAction)in
            guard let url = URL(string: "https://dash.akamaized.net/dash264/TestCasesIOP33/adapatationSetSwitching/5/manifest.mpd") else {
                return
            }
            self.player.play(url: url)
        }))

        alert.addAction(UIAlertAction(title: "onDemand profile, Audio", style: .default , handler:{ (UIAlertAction)in
            guard let url = URL(string: "https://download.tsi.telecom-paristech.fr/gpac/DASH_CONFORMANCE/TelecomParisTech/mp4-onDemand/mp4-onDemand-mpd-A.mpd") else {
                return
            }
            self.player.play(url: url)
        }))
        alert.addAction(UIAlertAction(title: "onDemand profile, Video", style: .default , handler:{ (UIAlertAction)in
            guard let url = URL(string: "https://download.tsi.telecom-paristech.fr/gpac/DASH_CONFORMANCE/TelecomParisTech/mp4-onDemand/mp4-onDemand-mpd-V.mpd") else {
                return
            }
            self.player.play(url: url)
        }))
        alert.addAction(UIAlertAction(title: "onDemand profile, Audio+Video", style: .default , handler:{ (UIAlertAction)in
            guard let url = URL(string: "https://download.tsi.telecom-paristech.fr/gpac/DASH_CONFORMANCE/TelecomParisTech/mp4-onDemand/mp4-onDemand-mpd-AV.mpd") else {
                return
            }
            self.player.play(url: url)
        }))

        alert.addAction(UIAlertAction(title: "full profile, without bitstream switching", style: .default , handler:{ (UIAlertAction)in
            guard let url = URL(string: "https://download.tsi.telecom-paristech.fr/gpac/DASH_CONFORMANCE/TelecomParisTech/mp4-full-gdr/mp4-full-gdr-mpd-AV-NBS.mpd") else {
                return
            }
            self.player.play(url: url)
        }))
        // means the video segments are not clean random-access / IDR-start segments. They use a GDR-style stream. That is often fine in DASH/MSE test content, but it is a bad fit for straightforward HLS/fMP4 playback in AVPlayer.
        alert.addAction(UIAlertAction(title: "full profile, with bitstream switching", style: .default , handler:{ (UIAlertAction)in
            guard let url = URL(string: "https://download.tsi.telecom-paristech.fr/gpac/DASH_CONFORMANCE/TelecomParisTech/mp4-full-gdr/mp4-full-gdr-mpd-AV-BS.mpd") else {
                return
            }
            self.player.play(url: url)
        }))

        alert.addAction(UIAlertAction(title: "main profile, ogop, without bitstream switching", style: .default , handler:{ (UIAlertAction)in
            guard let url = URL(string: "https://download.tsi.telecom-paristech.fr/gpac/DASH_CONFORMANCE/TelecomParisTech/mp4-main-ogop/mp4-main-ogop-mpd-AV-NBS.mpd") else {
                return
            }
            self.player.play(url: url)
        }))

        // means the video segments are not clean random-access / IDR-start segments. They use a GDR-style stream. That is often fine in DASH/MSE test content, but it is a bad fit for straightforward HLS/fMP4 playback in AVPlayer.
        alert.addAction(UIAlertAction(title: "main profile, ogop, with bitstream switching", style: .default , handler:{ (UIAlertAction)in
            guard let url = URL(string: "https://download.tsi.telecom-paristech.fr/gpac/DASH_CONFORMANCE/TelecomParisTech/mp4-main-ogop/mp4-main-ogop-mpd-AV-BS.mpd") else {
                return
            }
            self.player.play(url: url)
        }))
        
        alert.addAction(UIAlertAction(title: "live profile without bitstream switching", style: .default , handler:{ (UIAlertAction)in
            guard let url = URL(string: "https://download.tsi.telecom-paristech.fr/gpac/DASH_CONFORMANCE/TelecomParisTech/mp4-live/mp4-live-mpd-AV-NBS.mpd") else {
                return
            }
            self.player.play(url: url)
        }))

        alert.addAction(UIAlertAction(title: "HLS", style: .default , handler:{ (UIAlertAction)in
            guard let url = URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8") else {
                return
            }
            self.player.play(url: url)
        }))

        alert.addAction(UIAlertAction(title: "MP4", style: .default , handler:{ (UIAlertAction)in
            guard let url = URL(string: "https://avtshare01.rz.tu-ilmenau.de/avt-vqdb-uhd-1/test_1/segments/bigbuck_bunny_8bit_15000kbps_1080p_60.0fps_h264.mp4") else {
                return
            }
            self.player.play(url: url)
        }))

        alert.addAction(UIAlertAction(title: "Dismiss", style: .cancel, handler:{ (UIAlertAction)in
        }))

        self.present(alert, animated: true, completion: {
            print("completion block")
        })
    }
    
    // MARK: Events handlers
    
    @objc private func scrubberChanged(_ slider: UISlider) {
        let thumbRect = customScrubber.thumbRect(forBounds: customScrubber.bounds,
                                                 trackRect: customScrubber.trackRect(forBounds: customScrubber.bounds),
                                                 value: customScrubber.value)

        let thumbRectInParent = customScrubber.convert(thumbRect, to: customScrubber.superview)
        preview.center = CGPoint(x: thumbRectInParent.midX, y: thumbRectInParent.minY - 5 - 33.75)
        preview.image = player.thumbnail(at: Double(slider.value))
    }
    
    @objc private func scrubberTouchDown(_ slider: UISlider) {
        isScrubbing = true
        preview.isHidden = false
    }

    @objc private func scrubberTouchUp(_ slider: UISlider) {
        player.seek(Double(slider.value))
        isScrubbing = false
        preview.isHidden = true
    }
}

extension ViewController: UPlayerDelegate {
    func didEventPlayerStart(source: any UPlayerProtocol) {
        customScrubber.isHidden = !player.isThumbnailsSupported
    }
    
    func didEventPlayerPlay(source: any UPlayerProtocol) {
    }
    
    func didEventPlayerStop(source: any UPlayerProtocol, error: (any Error)?) {
    }
    
    func didEventPlayerChange(source: any UPlayerProtocol, isPaused: Bool) {
    }
    
    func didEventPlayerChange(source: any UPlayerProtocol, isMuted: Bool) {
    }
    
    func didEventPlayerChange(source: any UPlayerProtocol, rate: Double) {
    }
    
    func didEventPlayerChange(source: any UPlayerProtocol, playingTime: TimeInterval) {
        if isScrubbing {
            return
        }
        customScrubber.value = Float(playingTime)
    }
    
    func didEventPlayerChange(source: any UPlayerProtocol, duration: TimeInterval) {
        customScrubber.maximumValue = Float(duration)
    }
    
    func didEventPlayerReceiveVideoFrame(source: any UPlayerProtocol, frame: any VideoFrameProtocol) {
    }
    
    func didEventPlayerReceiveAudioFrame(source: any UPlayerProtocol, frame: any AudioFrameProtocol) {
    }
    
    var playerView: UPlayerView? {
        return view as? UPlayerView
    }
}

