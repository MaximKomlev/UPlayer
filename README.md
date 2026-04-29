#🎬 UPlayer — DASH → HLS Streaming Player for iOS

*UPlayer is a modular streaming pipeline that enables MPEG-DASH playback on iOS by dynamically converting MPD manifests into HLS playlists compatible with AVPlayer.

**It supports:

- ✅ DASH → HLS conversion (SegmentTemplate, SegmentBase, live & VOD)
- ✅ Custom AVAssetResourceLoader for virtual HLS (uplayer://)
- ✅ Live streaming with sliding window
- ✅ Thumbnail sprite parsing & scrubbing preview support
- ✅ Modular Combine-based processing pipeline
- ✅ Audio + Video adaptation sets
- ✅ MP4 fallback (SegmentBase / progressive)
- ✅ HLS and MP4 playback

##🚀 Features
###🎥 Playback

Works with AVPlayer
Seamless DASH playback via HLS translation

##Supports:

- VOD MPD (static)
- Live MPD (dynamic)
- SegmentTemplate (duration / timeline)
- SegmentBase (SIDX / byte-range)
- Multi-representation (adaptive bitrate)
- 🔄 Live Streaming
- MPD polling (minimumUpdatePeriod)
- Sliding HLS window generation
- Live edge control (stay N segments behind)
- Playlist merge strategy for continuity
- 🖼 Thumbnail Scrubbing
- Parses DASH image adaptation sets
- Supports tiled JPEG sprites
- Efficient caching (sprite + cropped image)
- Custom preview rendering for scrub UI

##🏗 Architecture

*Pipeline is built using Combine processors:

URL
 ↓
UPlayerMetadataDownloader
 ↓
UPlayerMPDParser
 ↓
UPlayerThumbnailDownloader
 ↓
UPlayerHLSGenerator / UPlayerSegmentBaseHLSGenerator / UPlayerMPDToMP4Resolver (fallback)
 ↓
UPlayerAVAssetResourceLoader (uplayer://)
 ↓
AVPlayer

##Each processor implements:

```swift
protocol UPlayerAssetProcessorProtocol {
    func process(asset: UPlayerAssetProtocol) -> AnyPublisher<UPlayerAssetProtocol, Error>
}
```

##📦 Core Components
🧩 Processors
Processor                           Purpose
UPlayerMetadataDownloader           Downloads MPD or detects media type
UPlayerMPDParser                    Parses DASH manifest
UPlayerThumbnailDownloader          Extracts + downloads thumbnail sprites
UPlayerHLSGenerator                 Generates HLS (SegmentTemplate)
UPlayerSegmentBaseHLSGenerator      Generates byte-range HLS
UPlayerMPDToMP4Resolver             Fallback to MP4
##🎞 Playback Layer
AVPlayer
AVPlayerItem
UPlayerAVAssetResourceLoader

**Custom scheme:
```swift
uplayer://...
```

##🧠 Live Controller

Handles:

- MPD refresh
- Playlist regeneration
- Segment merging

##🔌 Usage
1. Create player
let player = UPlayer()
2. Optionally assign a delegate (UPlayerDelegate) to monitor playback activity, 
and provide a rendering view when using a custom player controller.
player.delegate = self
3. Play DASH URL
uPlayer.play(url: URL(string: "https://example.com/manifest.mpd")!)
4. Stop playback
uPlayer.stop()

##🖼 Thumbnail Preview Example
```swift
if let cue = asset.thumbnailMetadata?.cue(for: scrubTime),
   let image = asset.thumbnailMetadata?.image(for: cue) {
    previewImageView.image = image
}
```
##⚠️ Important Notes

AVPlayer Behavior
AVPlayerViewController does NOT guarantee thumbnail preview
Use custom UI for scrubbing thumbnails
Live Streams
Must continuously update playlists
Otherwise you get:
Playlist File unchanged for longer than 1.5 * target duration
Pause Handling

For live streams:

Short pause → keep refreshing MPD
Long pause → detach player:
player.replaceCurrentItem(with: nil)

##🧪 Supported DASH Formats
✅ SegmentTemplate
<SegmentTemplate duration="2" media="$Number$.m4s" />
✅ SegmentBase
<SegmentBase indexRange="..." />
✅ Live MPD
<MPD type="dynamic" minimumUpdatePeriod="PT2S" />
✅ Thumbnail Tracks
<AdaptationSet mimeType="image/jpeg">

##🛠 Known Limitations
No DRM support (CENC)
No subtitles yet
No native AVPlayer thumbnail rendering
Requires custom UI for scrubbing preview

##📈 Roadmap
 LL-HLS support
 DRM (FairPlay / Widevine mapping)
 Subtitle tracks
 Smart bitrate selection
 Disk cache for thumbnails & segments

##👨‍💻 Author

Maxim Komleu

##📄 License

MIT License
