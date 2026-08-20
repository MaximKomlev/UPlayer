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
    private let assetCache = UPlayerAssetCache()
    private let mpdProcessors = UPlayerAssetProcessorsQueue()

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
        player.assetCache = assetCache
        player.delegate = self

        player.assetProcessorsQueue?.add(processor: UPlayerMetadataDownloader(id: "downloadAssetProcessor"))
        player.assetProcessorsQueue?.add(processor: UPlayerMPDParser(id: "mpdParserAssetProcessor"))
        player.assetProcessorsQueue?.add(processor: UPlayerThumbnailDownloader(id: "thumbnailDownloaderProcessor"))
        player.assetProcessorsQueue?.add(processor: UPlayerSegmentBaseHLSGenerator(id: "hlsSegmentBaseAssetProcessor"))
        player.assetProcessorsQueue?.add(processor: UPlayerMPDToMP4Resolver(id: "MPDToMP4ResolverAssetProcessor"))
        player.assetProcessorsQueue?.add(processor: UPlayerHLSGenerator(id: "hlsGeneratorAssetProcessor"))
        
        mpdProcessors.add(processor: UPlayerMetadataDownloader(id: "downloadAssetProcessor"))
        mpdProcessors.add(processor: UPlayerMPDParser(id: "mpdParserAssetProcessor"))
        mpdProcessors.add(processor: UPlayerThumbnailDownloader(id: "thumbnailDownloaderProcessor"))
        mpdProcessors.add(processor: UPlayerSegmentBaseHLSGenerator(id: "hlsSegmentBaseAssetProcessor"))
        mpdProcessors.add(processor: UPlayerMPDToMP4Resolver(id: "MPDToMP4ResolverAssetProcessor"))
        mpdProcessors.add(processor: UPlayerHLSGenerator(id: "hlsGeneratorAssetProcessor"))
        mpdProcessors.delegate = self
    }
            
    @objc private func rightNavBarButtonAction(sender: UIBarButtonItem) {
        let model = SourceViewControllerModel(
            title: "Choose Video",
            customURLTitle: "Custom Stream",
            customURLPlaceholder: "https://example.com/manifest.mpd",
            actionsTitle: "Test Streams",
            items: Self.demoItems
        )

        let controller = SourceViewController(model: model)
        controller.delegate = self

        let navigationController = UINavigationController(rootViewController: controller)
        navigationController.modalPresentationStyle = .fullScreen

        present(navigationController, animated: true)
    }
    
    private static var demoItems: [SourceViewControllerModel.Item] {
        [
            // MARK: - Preprocess

            SourceViewControllerModel.Item(title: "Preprocessing",
                                           subtitle: "Preprocess five urls simultaneously",
                                           url: URL(string: "https://localhost"),
                                           type: .preprocess),

            SourceViewControllerModel.Item(title: "Live",
                                           subtitle: "DASH-IF LiveSim, 2-second segments",
                                           url: URL(string: "https://livesim.dashif.org/livesim/testpic_2s/Manifest.mpd")),

            SourceViewControllerModel.Item(title: "MPD with preview",
                                           subtitle: "MPEG-DASH with tiled thumbnail previews",
                                           url: URL(string: "https://dash.akamaized.net/akamai/bbb_30fps/bbb_with_multiple_tiled_thumbnails.mpd")),

            SourceViewControllerModel.Item(title: "Segment template MPD",
                                           subtitle: "Big Buck Bunny, SegmentTemplate profile",
                                           url: URL(string: "https://ftp.itec.aau.at/datasets/DASHDataset2014/BigBuckBunny/15sec/BigBuckBunny_15s_simple_2014_05_09.mpd")),

            SourceViewControllerModel.Item(title: "Segment base MPD",
                                           subtitle: "Big Buck Bunny, SegmentBase/on-demand profile",
                                           url: URL(string: "https://ftp.itec.aau.at/datasets/DASHDataset2014/BigBuckBunny/15sec/BigBuckBunny_15s_onDemand_2014_05_09.mpd")),

            SourceViewControllerModel.Item(title: "Segment template MPD with Audio",
                                           subtitle: "Adaptation-set switching sample with audio",
                                           url: URL(string: "https://dash.akamaized.net/dash264/TestCasesIOP33/adapatationSetSwitching/5/manifest.mpd")),

            SourceViewControllerModel.Item(title: "onDemand profile, Audio",
                                           subtitle: "TelecomParisTech audio-only on-demand MPD",
                                           url: URL(string: "https://download.tsi.telecom-paristech.fr/gpac/DASH_CONFORMANCE/TelecomParisTech/mp4-onDemand/mp4-onDemand-mpd-A.mpd")),

            SourceViewControllerModel.Item(title: "onDemand profile, Video",
                                           subtitle: "TelecomParisTech video-only on-demand MPD",
                                           url: URL(string: "https://download.tsi.telecom-paristech.fr/gpac/DASH_CONFORMANCE/TelecomParisTech/mp4-onDemand/mp4-onDemand-mpd-V.mpd")),

            SourceViewControllerModel.Item(title: "onDemand profile, Audio + Video",
                                           subtitle: "TelecomParisTech A/V on-demand MPD",
                                           url: URL(string: "https://download.tsi.telecom-paristech.fr/gpac/DASH_CONFORMANCE/TelecomParisTech/mp4-onDemand/mp4-onDemand-mpd-AV.mpd")),

            SourceViewControllerModel.Item(title: "Full profile, without bitstream switching",
                                           subtitle: "GDR stream without bitstream switching",
                                           url: URL(string: "https://download.tsi.telecom-paristech.fr/gpac/DASH_CONFORMANCE/TelecomParisTech/mp4-full-gdr/mp4-full-gdr-mpd-AV-NBS.mpd")),

            SourceViewControllerModel.Item(title: "Full profile, with bitstream switching",
                                           subtitle: "GDR stream with bitstream switching",
                                           url: URL(string: "https://download.tsi.telecom-paristech.fr/gpac/DASH_CONFORMANCE/TelecomParisTech/mp4-full-gdr/mp4-full-gdr-mpd-AV-BS.mpd")),

            SourceViewControllerModel.Item(title: "Main profile, OGOP, without bitstream switching",
                                           subtitle: "Main profile OGOP without bitstream switching",
                                           url: URL(string: "https://download.tsi.telecom-paristech.fr/gpac/DASH_CONFORMANCE/TelecomParisTech/mp4-main-ogop/mp4-main-ogop-mpd-AV-NBS.mpd")),

            SourceViewControllerModel.Item(title: "Main profile, OGOP, with bitstream switching",
                                           subtitle: "Main profile OGOP with bitstream switching",
                                           url: URL(string: "https://download.tsi.telecom-paristech.fr/gpac/DASH_CONFORMANCE/TelecomParisTech/mp4-main-ogop/mp4-main-ogop-mpd-AV-BS.mpd")),

            SourceViewControllerModel.Item(title: "Live profile without bitstream switching",
                                           subtitle: "TelecomParisTech live profile",
                                           url: URL(string: "https://download.tsi.telecom-paristech.fr/gpac/DASH_CONFORMANCE/TelecomParisTech/mp4-live/mp4-live-mpd-AV-NBS.mpd")),

            SourceViewControllerModel.Item(title: "HLS",
                                           subtitle: "Apple fragmented MP4 HLS sample",
                                           url: URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8")),

            SourceViewControllerModel.Item(title: "MP4",
                                           subtitle: "Big Buck Bunny H.264 MP4",
                                           url: URL(string: "https://avtshare01.rz.tu-ilmenau.de/avt-vqdb-uhd-1/test_1/segments/bigbuck_bunny_8bit_15000kbps_1080p_60.0fps_h264.mp4"))
        ]
    }
    
    private func preProcessing() {
        if let url = URL(string: "https://livesim.dashif.org/livesim/testpic_2s/Manifest.mpd"),
           (try? self.assetCache.asset(url: url)) == nil {
            let asset = UPlayerAsset(url: url)
            self.mpdProcessors.start(asset: asset)
        }

        if let url = URL(string: "https://dash.akamaized.net/akamai/bbb_30fps/bbb_with_multiple_tiled_thumbnails.mpd"),
           (try? self.assetCache.asset(url: url)) == nil {
            let asset = UPlayerAsset(url: url)
            self.mpdProcessors.start(asset: asset)
        }
        
        if let url = URL(string: "https://ftp.itec.aau.at/datasets/DASHDataset2014/BigBuckBunny/15sec/BigBuckBunny_15s_simple_2014_05_09.mpd"),
           (try? self.assetCache.asset(url: url)) == nil {
            let asset = UPlayerAsset(url: url)
            self.mpdProcessors.start(asset: asset)
        }

        if let url = URL(string: "https://ftp.itec.aau.at/datasets/DASHDataset2014/BigBuckBunny/15sec/BigBuckBunny_15s_onDemand_2014_05_09.mpd"),
           (try? self.assetCache.asset(url: url)) == nil {
            let asset = UPlayerAsset(url: url)
            self.mpdProcessors.start(asset: asset)
        }

        if let url = URL(string: "https://dash.akamaized.net/dash264/TestCasesIOP33/adapatationSetSwitching/5/manifest.mpd"),
           (try? self.assetCache.asset(url: url)) == nil {
            let asset = UPlayerAsset(url: url)
            self.mpdProcessors.start(asset: asset)
        }
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

extension ViewController: UPlayerAssetProcessorsQueueDelegate {
    func didStartProcessing(source: any UPlayerAssetProcessorsQueueProtocol) {
    }
    
    func didFinishProcessing(source: any UPlayerAssetProcessorsQueueProtocol, error: (any Error)?) {
    }
    
    func didFinishProcessing(source: any UPlayerAssetProcessorsQueueProtocol, asset: any UPlayerAssetProtocol) {
        if asset.mpdMetadata?.manifestType == .dynamicLive {
            return
        }
        assetCache.addAsset(asset)
    }
}

extension ViewController: SourceViewControllerDelegate {
    func videoSelectionViewController(_ controller: SourceViewController, didSelect item: SourceViewControllerModel.Item?, customURL: URL?) {
        if let customURL {
            player.play(url: customURL)
            return
        }

        guard let item,
              let url = item.url else {
            return
        }

        switch item.type {
        case .play:
            player.play(url: url)

        case .preprocess:
            preProcessing()
        }
    }
    
    func videoSelectionViewControllerDidCancel(_ controller: SourceViewController) {
        
    }
}
