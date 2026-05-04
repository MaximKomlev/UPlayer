# 🎬 UPlayer — DASH → HLS Streaming Player for iOS

*UPlayer is a modular streaming pipeline that enables MPEG-DASH playback on iOS by dynamically converting MPD manifests into HLS playlists compatible with AVPlayer.*

**It supports:**

- ✅ DASH → HLS conversion (SegmentTemplate, SegmentBase, live & VOD)
- ✅ Custom AVAssetResourceLoader for virtual HLS (uplayer://)
- ✅ Live streaming with sliding window
- ✅ Thumbnail sprite parsing & scrubbing preview support
- ✅ Modular Combine-based processing pipeline
- ✅ Audio + Video adaptation sets
- ✅ MP4 fallback (SegmentBase / progressive)
- ✅ HLS and MP4 playback

## 🚀 Features
### 🎥 Playback

Works with AVPlayer
Seamless DASH playback via HLS translation

## Supports:

- VOD MPD (static)
- Live MPD (dynamic)
- SegmentTemplate (duration / timeline)
- SegmentBase (SIDX / byte-range)
- Multi-representation (adaptive bitrate)
- **🔄 Live Streaming**
- MPD polling (minimumUpdatePeriod)
- Sliding HLS window generation
- Live edge control (stay N segments behind)
- Playlist merge strategy for continuity
- **🖼 Thumbnail Scrubbing**
- Parses DASH image adaptation sets
- Supports tiled JPEG sprites
- Efficient caching (sprite + cropped image)
- Custom preview rendering for scrub UI

## 🏗 Architecture

**Pipeline is built using Combine processors:**

```
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
```

**Each processor implements:**

```swift
protocol UPlayerAssetProcessorProtocol {
    func process(asset: UPlayerAssetProtocol) -> AnyPublisher<UPlayerAssetProtocol, Error>
}
```

## 📦 Core Components
### 🧩 Processors

|Processor|Purpose|
| ----------- | ----------- |
|UPlayerMetadataDownloader|Downloads MPD or detects media type|
|UPlayerMPDParser|Parses DASH manifest|
|UPlayerThumbnailDownloader|Extracts + downloads thumbnail sprites|
|UPlayerHLSGenerator|Generates HLS (SegmentTemplate)|
|UPlayerSegmentBaseHLSGenerator|Generates byte-range HLS|
|UPlayerMPDToMP4Resolver|Fallback to MP4|

## 🎞 Playback Layer
AVPlayer
AVPlayerItem
UPlayerAVAssetResourceLoader

**Custom scheme:**
```swift
uplayer://...
```

## 🧠 Live Controller

Handles:

- MPD refresh
- Playlist regeneration
- Segment merging

## 🔌 Usage
1. Create player
```swift
let player = UPlayer()
```
2. Optionally assign a delegate (**UPlayerDelegate**) to monitor playback activity, 
and provide a rendering view when using a custom player controller.
```swift
player.delegate = self
```
3. Play DASH URL
```swift
uPlayer.play(url: URL(string: "https://example.com/manifest.mpd")!)
```
4. Stop playback
```swift
uPlayer.stop()
```

## 🖼 Thumbnail Preview Example
```swift
if let cue = asset.thumbnailMetadata?.cue(for: scrubTime),
   let image = asset.thumbnailMetadata?.image(for: cue) {
    previewImageView.image = image
}
```
## ⚠️ Important Notes

AVPlayer Behavior
*AVPlayerViewController does NOT guarantee thumbnail preview
Use custom UI for scrubbing thumbnails*
Live Streams
Must continuously update playlists
Otherwise you get:
Playlist File unchanged for longer than 1.5 * target duration
Pause Handling

For live streams:

Short pause → keep refreshing MPD
Long pause → detach player:
player.replaceCurrentItem(with: nil)

## 🧪 Supported DASH Formats
✅ SegmentTemplate
<SegmentTemplate duration="2" media="$Number$.m4s" />
✅ SegmentBase
<SegmentBase indexRange="..." />
✅ Live MPD
<MPD type="dynamic" minimumUpdatePeriod="PT2S" />
✅ Thumbnail Tracks
<AdaptationSet mimeType="image/jpeg">

# 🔊 Audio Transcoding (On-Demand)

*UPlayer supports automatic audio transcoding for DASH streams when the original audio codec is not compatible with AVPlayer.*

**This is critical because iOS AVPlayer supports only a limited set of audio codecs, primarily:**

- ✅ mp4a.40.2 (AAC-LC)
- ✅ mp4a.40.5 (HE-AAC)
- ✅ mp4a.40.29 (HE-AAC v2)
- ❌ Unsupported Audio Codecs

## When DASH contains unsupported audio, playback will fail or audio will be ignored.

**Examples:**

- ec-3 (Dolby Digital Plus)
- ac-3
- g711 (pcma, pcmu)
- non-standard or malformed mp4a.*

## ⚙️ How UPlayer Handles It

**1. Detection (HLS Generator)**

During DASH → HLS conversion:

Audio representations are analyzed
Codec is normalized (e.g. mp4a.40.02 → mp4a.40.2)
If unsupported → transcoding is enabled

**2. URL Rewriting**

Unsupported audio segments are rewritten to a custom scheme:
```
uplayer://example.com/audio/seg_1.m4s?mode=audio-transcode&codec=ec-3
```
This allows interception by:

UPlayerAVAssetResourceLoader

**3. Resource Loader Interception**

When AVPlayer requests the segment:

mode=audio-transcode

the loader:

Converts URL → original HTTPS URL
Downloads original segment
Extracts audio samples (if needed)
Transcodes audio → AAC
Returns data to AVPlayer

**4. Transcoding Pipeline**

```
Original segment (m4s/mp4)
 ↓
(optional) MP4 demux
 ↓
Audio samples (e.g. G.711 / EC-3)
 ↓
Decode → PCM
 ↓
Encode → AAC (LC)
 ↓
Wrap → ADTS
 ↓
Return to AVPlayer
```

**5. HLS Master Playlist Adjustment**

When transcoding is enabled:

CODECS="mp4a.40.2"

Even if original codec was:

ec-3 / pcma / pcmu
## 📦 Implementation Components

🔹 HLS Generators

UPlayerHLSGenerator
UPlayerSegmentBaseHLSGenerator

Responsible for:

detecting unsupported audio
rewriting URLs to uplayer://

🔹 Resource Loader
UPlayerAVAssetResourceLoader

Handles:

intercepting custom scheme
downloading original media
invoking transcoder
returning transformed data

🔹 Transcoder
UPlayerG711ToAACTranscoder
UPlayerAACADTSEncoder

Responsibilities:

- decode source audio → PCM
- encode PCM → AAC
- output ADTS stream

## ⚠️ Important Notes

**1. ADTS vs fMP4**

Transcoded audio uses:

AAC + ADTS

So:

❌ Do NOT include #EXT-X-MAP
✅ Use .aac segments

**2. Codec Consistency**

The codec declared in HLS must match transcoder output:

**mp4a.40.2**

Mismatch causes:

❌ no audio
❌ playback stalls

**3. Performance Considerations**

Transcoding is CPU-intensive:

happens per segment
may increase startup latency
may require caching

Recommended:

cache transcoded segments
reuse decoded PCM when possible

**4. Live Streams**

For live DASH:

transcoding happens continuously
ensure:
sliding window HLS playlists
segment caching
stable timestamps

## 🧪 When Transcoding is Triggered
|Codec|Action
| ----------- | ----------- |
|mp4a.40.2|pass-through|
|mp4a.40.5|pass-through|
|mp4a.40.29|pass-through|
|ec-3|transcode|
|ac-3|transcode|
|pcma / pcmu|transcode|
|unknown|pass-through|

## 🧠 Summary

UPlayer ensures compatibility by:

Detecting unsupported audio codecs
Routing them through a custom pipeline
Transcoding to AAC
Presenting a clean HLS stream to AVPlayer

## 🛠 Known Limitations
No DRM support (CENC)
No subtitles yet
No native AVPlayer thumbnail rendering
Requires custom UI for scrubbing preview

## 📈 Roadmap
 LL-HLS support
 DRM (FairPlay / Widevine mapping)
 Subtitle tracks
 Smart bitrate selection
 Disk cache for thumbnails & segments

## 👨‍💻 Author

Maxim Komleu

## 📄 License

MIT License
