# iOS Recording Implementation Plan

## Current State
- HaishinKit.swift is pulled from GitHub (exact: 2.2.5) in Package.swift
- HaishinKit already has a `StreamRecorder` actor that can record to MP4/MOV
- SRT streaming works via SRTStream which outputs to OutgoingStream
- iOS native plugin is in `plugins/station_broadcast/ios/station_broadcast/`

## HaishinKit StreamRecorder Architecture

### Capabilities
✅ Records to MP4/MOV files  
✅ Supports configurable video codec (H.264, HEVC)  
✅ Supports configurable audio codec (AAC)  
✅ Allows custom bitrate, resolution, FPS settings  
✅ Saves to Documents directory (accessible via Photos/Files app)  
✅ Can be attached as output to streaming (similar to Android's DualStreamer.second)  
✅ Movie fragment interval support (crash-resilient)  

### Key Classes
- **StreamRecorder**: Main recorder actor
  - `startRecording(_ url: URL, settings: [AVMediaType: [String: any Sendable]])`
  - `stopRecording() async throws`
  - `isRecording: Bool`
  - `outputURL: URL?`
  - `error: AsyncStream<StreamRecorder.Error>`

### Default Settings Structure
```swift
[AVMediaType: [String: any Sendable]] = [
    .audio: [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 0,      // 0 = auto from input
        AVNumberOfChannelsKey: 0  // 0 = auto from input
    ],
    .video: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoHeightKey: 0,      // 0 = auto from input
        AVVideoWidthKey: 0        // 0 = auto from input
    ]
]
```

## Architecture Comparison: Android vs iOS

### Android (StreamPack DualStreamer)
```
Camera → DualStreamer
  ├─ First Encoder (Stream: 1280x720@25fps H.264 3Mbps)
  └─ Second Encoder (Recording: 1920x1080@25fps H.264 6Mbps) → MediaStore
```

### iOS (HaishinKit StreamRecorder)
```
Camera → OutgoingStream
  ├─ Network Output (SRTStream: 1280x720@25fps)
  └─ StreamRecorder Output (MP4 File: 1920x1080@25fps) ← TO IMPLEMENT
```

**Key Difference**: iOS uses a "tee" pattern where the camera feed flows through OutgoingStream, which can have multiple outputs (network + recorder). Android uses independent dual encoders.

## Implementation Plan

### Phase 1: iOS Native Plugin Updates (Swift)
**File**: `plugins/station_broadcast/ios/station_broadcast/Sources/station_broadcast.swift`

1. **Add StreamRecorder instance to BroadcastEngine**
   ```swift
   private var recordingStream: StreamRecorder?
   ```

2. **Update initialize() to accept recording settings**
   - Similar to Android: recordingEnabled, recordingResolution, recordingBitrateBps, recordingFps, recordingCodec
   - Create recording directory if needed
   - Configure StreamRecorder default settings

3. **Add startRecordingStream() method**
   - Create recording file path with timestamp: `stationcast_YYYYMMDD_HHMMSS.mp4`
   - Build settings dict with configurable video codec and bitrate
   - Call `recordingStream.startRecording()`
   - Emit recording started event with file path

4. **Add stopRecordingStream() method**
   - Call `recordingStream.stopRecording()`
   - Emit recording stopped event

5. **Update publish() flow**
   - When recording enabled: attach recorder as output to OutgoingStream
   - Pass recorder into the stream pipeline

### Phase 2: Flutter Plugin Interface (Dart)
**File**: `plugins/station_broadcast/lib/station_broadcast.dart`

1. **Add native methods** (already exists from Android refactor)
   - `initializeWithRecording()` - existing
   - `startStreamWithRecording()` - existing

2. **No changes needed** - Dart interface already mirrors Android

### Phase 3: Settings & UI
**Dart files already updated for Android** - iOS uses same models:
- `lib/models/recording_settings.dart` ✅
- `lib/broadcast/broadcast_controller.dart` ✅
- `lib/ui/settings_screen.dart` ✅

## Resolution Mapping for iOS

Similar to Android, map enum to AVCaptureSession preset + dimensions:

| RecordingResolution | Preset | Dimensions |
|---|---|---|
| p720 | high | 1280x720 |
| p1080 | high | 1920x1080 |
| p1440 | high | 2560x1440 |

## File Saving Strategy

### iOS Photos App Visibility
- **On iOS 14+**: Files saved to Documents app are accessible in Files app
- **Photos.app**: Needs to be in Photos Library (requires Photos framework)
- **Strategy**: Save to Documents/Movies/StationCast (similar to Android)

### File Naming
```
stationcast_20260717_101356.mp4
```

## Implementation Order

1. **Modify HaishinKit fork to expose StreamRecorder publicly** (if not already)
   - Check SRTStream if it has public access to outputs
   - May need to add helper methods to attach recorder

2. **Implement recorder in station_broadcast plugin**
   - Create recorder instance
   - Add file path handling
   - Add settings configuration
   - Integrate with publish() flow

3. **Add event channels**
   - recordingStarted(filePath)
   - recordingStopped()
   - recordingError(message)

4. **Test on iOS device**
   - Recording starts/stops correctly
   - File appears in Files app
   - Quality settings work (resolution, bitrate, FPS, codec)
   - Audio + video sync
   - No dropped frames

## Key Differences from Android

| Aspect | Android | iOS |
|---|---|---|
| Arch | Dual Independent Encoders | Single camera + tee'd outputs |
| Recorder | StreamPack built-in | HaishinKit built-in |
| File Access | MediaStore API | Documents + Files app |
| Codec Config | Per-encoder | Via AVAssetWriter settings |
| Quality Independent | ✅ Full dual encoding | ✅ Via settings dict |

## Risks & Mitigation

| Risk | Mitigation |
|---|---|
| Recorder not exposed publicly in SRTStream | Check fork; modify if needed |
| Audio/video sync issues | Use HaishinKit's built-in sync (CMTime) |
| Memory with dual encoding | Monitor with Xcode instruments |
| Photos.app visibility | Document Files app access; research Photos.framework if needed |

## Next Steps
1. Review forked HaishinKit in tmp directory
2. Check SRTStream's output attachment mechanism
3. Implement swift code for recording
4. Test recording start/stop
5. Verify file quality and accessibility