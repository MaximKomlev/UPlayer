Pod::Spec.new do |s|
  s.name             = 'UPlayer'
  s.version          = '1.0.0'

  s.summary          = 'MPEG-DASH and HLS player framework for iOS.'
  s.description      = <<-DESC
UPlayer is an iOS media playback framework built on AVPlayer.

It adds MPEG-DASH playback support by parsing MPD manifests and
generating AVPlayer-compatible HLS playlists, including support for
live streams, SegmentTemplate, SegmentBase, thumbnail previews,
and on-demand audio transcoding.
                       DESC

  s.homepage         = 'https://github.com/MaximKomlev/UPlayer'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'Maxim Komlev' => 'komlev.maxim@gmail.com' }

  s.source           = {
    :git => 'https://github.com/MaximKomlev/UPlayer.git',
    :tag => s.version.to_s
  }

  s.platform         = :ios, '16.0'
  s.swift_version    = '5.0'

  s.source_files     = 'Sources/UPlayer/**/*.{swift,h,m}'

  s.frameworks = [
    'UIKit',
    'AVKit',
    'CoreMedia',
    'Foundation',
    'AVFoundation',
    'AudioToolbox'
  ]

  s.requires_arc = true
end
