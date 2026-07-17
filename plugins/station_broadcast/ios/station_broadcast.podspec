#
# station_broadcast — SRT/RTMP broadcast engine wrapping HaishinKit.
#
# NOTE: The recommended integration is Swift Package Manager
# (`flutter config --enable-swift-package-manager`), which pins
# HaishinKit 2.2.5 via ios/station_broadcast/Package.swift.
# CocoaPods trunk only carries HaishinKit 2.0.x; this podspec exists as a
# fallback and may lag the SPM path.
#
Pod::Spec.new do |s|
  s.name             = 'station_broadcast'
  s.version          = '0.1.0'
  s.summary          = 'SRT/RTMP camera+mic broadcast engine for Flutter.'
  s.description      = <<-DESC
SRT/RTMP camera and microphone broadcast engine for Flutter, wrapping HaishinKit.
                       DESC
  s.homepage         = 'https://stationcast.tv'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'StationCast' => 'dev@stationcast.tv' }
  s.source           = { :path => '.' }
  s.source_files = 'station_broadcast/Sources/station_broadcast/**/*.swift'
  s.dependency 'Flutter'
  s.dependency 'HaishinKit', '~> 2.0'
  s.dependency 'SRTHaishinKit', '~> 2.0'
  s.platform = :ios, '15.0'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.9'
end
