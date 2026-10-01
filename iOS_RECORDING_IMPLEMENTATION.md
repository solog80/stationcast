# iOS Recording Implementation Guide

## HaishinKit Architecture Analysis

### Key Findings
✅ **StreamRecorder** is built-in to HaishinKit  
✅ **StreamOutput protocol** - StreamRecorder conforms to this  
✅ **Attachment pattern** - `stream.addOutput(recorder)`  
✅ **Auto buffer handling** - Stream automatically sends audio/video frames  

### Protocol Flow
```swift
// StreamConvertible protocol (implemented by SRTStream/RTMPStream)
protocol StreamConvertible: Actor, MediaMixerOutput {
    func addOutput(_ observer: some StreamOutput)
    func removeOutput(_ observer: some StreamOutput)
}

// StreamOutput protocol (implemented by StreamRecorder)
protocol StreamOutput: AnyObject, Sendable {
    func stream(_ stream: some StreamConvertible, didOutput audio: AVAudioBuffer, when: AVAudioTime)
    func stream(_ stream: some StreamConvertible, didOutput video: CMSampleBuffer)
}
```

## Implementation Architecture

### Data Flow for iOS Recording
```
CaptureSession
    ↓
SRTStream (StreamConvertible)
    ├─→ Network Output (SRT transmission)
    └─→ StreamRecorder (StreamOutput) → AVAssetWriter → MP4 File
```

### Initialization Sequence
1. Create SRTConnection & SRTStream
2. Optionally create StreamRecorder (if recording enabled)
3. Call `stream.addOutput(recorder)` to attach
4. When publish() called → stream auto-sends buffers to recorder

## iOS Plugin Implementation

### File: `plugins/station_broadcast/ios/station_broadcast/Sources/station_broadcast.swift`

#### 1. Add Imports (if not present)
```swift
import HaishinKit
import SRTHaishinKit
```

#### 2. Add to BroadcastEngine class
```swift
private var recordingStream: StreamRecorder?
private var recordingFilePath: String?
private let recordingQueue = DispatchQueue(label: "io.stationcast.recording")
```

#### 3. Add Recording Configuration Method
```swift
func configureRecording(
    enabled: Bool,
    resolution: String,
    bitrateBps: Int,
    fps: Int,
    codec: String
) {
    guard enabled else {
        recordingStream = nil
        return
    }
    
    // Create recorder instance
    recordingStream = StreamRecorder()
    
    // Configure settings based on resolution
    let dimensions = resolveRecordingDimensions(resolution)
    let codecType = resolveVideoCodec(codec)
    
    // Default settings structure
    var recordingSettings: [AVMediaType: [String: any Sendable]] = [
        .audio: [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 0,        // Auto from input
            AVNumberOfChannelsKey: 0   // Auto from input
        ],
        .video: [
            AVVideoCodecKey: codecType,
            AVVideoHeightKey: Int(dimensions.height),
            AVVideoWidthKey: Int(dimensions.width),
            AVVideoAverageBitRateKey: bitrateBps,
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrateBps,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps  // Keyframe every 1 second
            ]
        ]
    ]
    
    Task {
        await recordingStream?.settings = recordingSettings
    }
}

private func resolveRecordingDimensions(_ resolution: String) -> (width: UInt32, height: UInt32) {
    switch resolution {
    case "p720":
        return (1280, 720)
    case "p1080":
        return (1920, 1080)
    case "p1440":
        return (2560, 1440)
    default:
        return (1920, 1080)
    }
}

private func resolveVideoCodec(_ codec: String) -> AVVideoCodecType {
    switch codec {
    case "hevc":
        return .hevc
    case "h264":
        return .h264
    default:
        return .h264
    }
}
```

#### 4. Update initialize() Method
```swift
func initialize(_ args: [String: Any]) async {
    // ... existing code ...
    
    // Extract recording settings
    let recordingEnabled = args["recordingEnabled"] as? Bool ?? false
    let recordingResolution = args["recordingResolution"] as? String ?? "p1080"
    let recordingBitrateBps = args["recordingBitrateBps"] as? Int ?? 6_000_000
    let recordingFps = args["recordingFps"] as? Int ?? 25
    let recordingCodec = args["recordingCodec"] as? String ?? "h264"
    
    // Configure recording if enabled
    if recordingEnabled {
        configureRecording(
            enabled: true,
            resolution: recordingResolution,
            bitrateBps: recordingBitrateBps,
            fps: recordingFps,
            codec: recordingCodec
        )
    }
}
```

#### 5. Update publish() Method
```swift
func publish(_ streamName: String) async {
    // ... existing SRT setup code ...
    
    // Attach recorder BEFORE calling stream.publish()
    if let recorder = recordingStream {
        await stream.addOutput(recorder)
        log("Recording stream attached")
    }
    
    // Now publish the stream (which will start sending buffers)
    await stream.publish(streamName)
}
```

#### 6. Add startRecording() Method
```swift
func startRecording(recordingEnabled: Bool) async {
    guard recordingEnabled, let recorder = recordingStream else {
        return
    }
    
    do {
        // Create recording directory
        let fileManager = FileManager.default
        let documentURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let recordingDir = documentURL.appendingPathComponent("Movies/StationCast", isDirectory: true)
        
        try fileManager.createDirectory(at: recordingDir, withIntermediateDirectories: true)
        
        // Generate filename with timestamp
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = dateFormatter.string(from: Date())
        let filename = "stationcast_\(timestamp).mp4"
        let recordingURL = recordingDir.appendingPathComponent(filename)
        
        // Start recording
        try await recorder.startRecording(recordingURL)
        recordingFilePath = recordingURL.absoluteString
        
        // Send event to Flutter
        eventChannel?.send("recordingStarted", data: recordingFilePath)
        log("Recording started: \(recordingURL.path)")
        
    } catch {
        log("Recording error: \(error)")
        eventChannel?.send("recordingError", data: error.localizedDescription)
    }
}
```

#### 7. Add stopRecording() Method
```swift
func stopRecording() async {
    guard let recorder = recordingStream else {
        return
    }
    
    do {
        try await recorder.stopRecording()
        eventChannel?.send("recordingStopped", data: recordingFilePath)
        log("Recording stopped: \(recordingFilePath ?? "unknown")")
        recordingFilePath = nil
    } catch {
        log("Recording stop error: \(error)")
    }
}
```

#### 8. Update stopStream() Method
```swift
func stopStream() async {
    if recordingEnabled {
        await stopRecording()
    }
    
    // ... existing stop code ...
}
```

## Settings Dictionary Deep Dive

### Video Settings Structure
```swift
[
    AVVideoCodecKey: AVVideoCodecType.h264,  // or .hevc
    AVVideoHeightKey: 1080,
    AVVideoWidthKey: 1920,
    AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: 6_000_000,
        AVVideoExpectedSourceFrameRateKey: 25,
        AVVideoMaxKeyFrameIntervalKey: 25,      // Keyframe every 1 sec
        AVVideoProfileLevelKey: AVVideoProfileLevelH264Main40  // For H.264
    ]
]
```

### Audio Settings Structure
```swift
[
    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
    AVSampleRateKey: 0,          // 0 = auto from input (44.1kHz or 48kHz)
    AVNumberOfChannelsKey: 0,    // 0 = auto from input (1 or 2)
    AVEncoderBitRateKey: 128000  // Optional: override bitrate
]
```

## Event Channel Integration

### Add to FlutterMethodChannel setup
```swift
let eventChannel = FlutterEventChannel(
    name: "io.stationcast/broadcast/recording",
    binaryMessenger: controller.binaryMessenger
)
eventChannel.setStreamHandler(self)
```

### Events to emit
1. **recordingStarted** - `{ filePath: String }`
2. **recordingStopped** - `{ filePath: String }`
3. **recordingError** - `{ message: String }`

## Key Differences from Android

| Aspect | Android (StreamPack) | iOS (HaishinKit) |
|---|---|---|
| Architecture | Dual independent encoders | Tee'd outputs |
| Attachment | DualStreamer.second | stream.addOutput() |
| Buffer delivery | Via StreamPack pipeline | Via StreamOutput protocol |
| Quality control | Independent codec instances | Single codec → multiple outputs |

## Testing Checklist

- [ ] Recording starts when publish() called
- [ ] File created in Documents/Movies/StationCast/
- [ ] File has correct name pattern: `stationcast_YYYYMMDD_HHMMSS.mp4`
- [ ] Events emit correctly (start/stop)
- [ ] Video codec selector works (H.264 vs HEVC)
- [ ] Resolution selector works (720p, 1080p, 1440p)
- [ ] Bitrate adjustment reflects in file size
- [ ] FPS setting affects frame count
- [ ] Audio + video sync is correct
- [ ] File is playable immediately after stop
- [ ] File visible in Files app
- [ ] Stop recording on network error

## Notes on HaishinKit Behavior

1. **Auto-configuration**: Settings with 0 values auto-detect from input stream
2. **Async/await**: All recording methods are async - use `Task { await ... }`
3. **AVAssetWriter**: Under the hood, uses AVAssetWriter for MP4 muxing
4. **Thread safety**: StreamRecorder is an actor - automatically thread-safe
5. **Error handling**: Check `.error` AsyncStream for recording failures
6. **Movie fragments**: Optional crash resilience via `movieFragmentInterval`

## Swift Concurrency Model

```swift
// Create recorder
let recorder = StreamRecorder()

// Configure
var settings = StreamRecorder.defaultSettings
settings[.video]?[AVVideoCodecKey] = AVVideoCodecType.hevc
await recorder.settings = settings  // await because it's an actor

// Start (throws if invalid state)
try await recorder.startRecording(url)

// Listen for errors
Task {
    for await error in await recorder.error {
        print("Recording error: \(error)")
    }
}

// Stop
try await recorder.stopRecording()
```

## Integration with Flutter Recording Settings

The Dart RecordingSettings model maps directly:

```dart
RecordingSettings(
    resolution: RecordingResolution.p1080,  // → "p1080"
    bitrateBps: 6_000_000,                  // → AVVideoAverageBitRateKey
    fps: RecordingFps.fps25,                // → AVVideoExpectedSourceFrameRateKey
    codec: BroadcastVideoCodec.h264,        // → AVVideoCodecType.h264
    enabled: true                           // → recordingEnabled
)
```

All Flutter models and UI already exist - iOS just needs to implement the native side!