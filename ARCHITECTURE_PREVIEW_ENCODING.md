# Dual Preview + ImageAnalysis Architecture

## Objective
Enable real-time camera preview during streaming (no blackout/pause) while simultaneously encoding video frames for SRT streaming. This matches the StreamLab/StreamPack behavior where preview remains active during broadcast.

## Problem Statement
CameraX's Preview UseCase can only output to ONE surface at a time. Previous approach:
- Go live → switch camera to encoder surface → preview pauses (BLACK SCREEN)
- Stop streaming → switch back to preview surface → preview resumes

User requirement: Preview must stay active during streaming (real-time like StreamLab)

## Solution: Dual UseCase Binding
Use TWO simultaneous CameraX UseCases on the same camera:

### 1. Preview UseCase
- **Purpose**: Display camera feed to user
- **Output**: SurfaceView (native Android view)
- **Always active**: Yes
- **Resolution**: 1920x1080
- **Status**: ✅ Implemented in CameraXManager.kt (lines ~90-105)

### 2. ImageAnalysis UseCase
- **Purpose**: Capture raw YUV frames for encoding
- **Output**: ImageProxy frames via callback
- **Always active**: Yes  
- **Resolution**: 1280x720
- **Frame rate**: ~30fps with STRATEGY_KEEP_ONLY_LATEST
- **Status**: ✅ Implemented in CameraXManager.kt (lines ~107-123)

### 3. Encoder (MediaCodec)
- **Purpose**: Encode raw frames to H.264 bitstream
- **Input**: Raw YUV frames from ImageAnalysis
- **Output**: Encoded H.264 frames
- **Status**: ⚠️ NEEDS UPDATE - currently expects Surface, needs to accept raw frames

## Key Files Modified

### CameraXManager.kt
**Status**: ✅ UPDATED

**Changes**:
- Added `var onFrameAvailable: ((ImageProxy) -> Unit)? = null` callback
- Updated `bindCamera()` to bind BOTH Preview and ImageAnalysis
- ImageAnalysis set to capture YUV frames and invoke callback
- Preview continues to display to SurfaceView independently

**Code flow**:
```
Camera → Preview UseCase → SurfaceView (display)
      ↓
      ImageAnalysis UseCase → onFrameAvailable callback → Raw YUV frames
```

**File path**: `/plugins/station_broadcast/android/src/main/kotlin/tv/stationcast/station_broadcast/CameraXManager.kt`

### VideoEncoder.kt
**Status**: ⚠️ NEEDS REFACTOR

**Current issue**: 
- Configured to use `createInputSurface()` which expects data from camera/render thread
- Cannot directly accept raw YUV frames from ImageAnalysis

**What needs to be done**:
1. Add new method `encodeFrame(imageProxy: ImageProxy, presentationTimeUs: Long)`
2. Extract YUV data from ImageProxy
3. Write to MediaCodec input buffers directly (NOT via Surface)
4. Reconfigure MediaCodec:
   ```kotlin
   // Instead of:
   inputSurface = createInputSurface()
   
   // Use:
   mediaCodec.getInputBuffer(index).put(yuvData)
   mediaCodec.queueInputBuffer(index, 0, yuvData.size, pts, flags)
   ```

**File path**: `/plugins/station_broadcast/android/src/main/kotlin/tv/stationcast/station_broadcast/VideoEncoder.kt`

### BroadcastEngineNew.kt
**Status**: ⚠️ NEEDS UPDATE

**Changes needed**:
1. Set up frame callback from CameraXManager
2. Feed frames to VideoEncoder via new `encodeFrame()` method
3. Remove `switchToEncoderSurface()` calls (no longer needed)
4. Keep preview always active (no surface switching)

**Pseudocode**:
```kotlin
cameraManager?.onFrameAvailable = { imageProxy ->
    videoEncoder?.encodeFrame(imageProxy, imageProxy.image.timestamp)
}
```

**File path**: `/plugins/station_broadcast/android/src/main/kotlin/tv/stationcast/station_broadcast/BroadcastEngineNew.kt`

### CameraPreviewPlatformView.kt
**Status**: ✅ NO CHANGES NEEDED
- Still receives SurfaceView surface from Preview UseCase
- Preview displays continuously without interruption

**File path**: `/plugins/station_broadcast/android/src/main/kotlin/tv/stationcast/station_broadcast/CameraPreviewPlatformView.kt`

## Implementation Checklist

### Phase 1: Frame Encoding (IN PROGRESS)
- [ ] Refactor VideoEncoder to accept raw YUV frames
  - [ ] Add `encodeFrame(imageProxy, pts)` method
  - [ ] Change MediaCodec configuration from Surface to buffer-based
  - [ ] Handle YUV format conversion if needed (usually NV21 or YUV_420_888)
  - [ ] Update encoding thread to dequeue output properly

- [ ] Connect CameraXManager frames to VideoEncoder
  - [ ] Set `cameraManager.onFrameAvailable` callback in BroadcastEngineNew
  - [ ] Feed ImageProxy to `videoEncoder.encodeFrame()`
  - [ ] Handle frame timing (presentationTimeUs)

- [ ] Remove surface-switching code
  - [ ] Delete or disable `switchToEncoderSurface()` 
  - [ ] Delete `restorePreviewSurface()`
  - [ ] Simplify BroadcastEngineNew stream lifecycle

### Phase 2: SRT Streaming (DEFERRED)
- [ ] Implement actual SRT socket sending
- [ ] Send encoded frames to SRT destination
- [ ] Track bitrate properly
- [ ] Handle connection errors

## Technical Challenges & Solutions

### Challenge 1: YUV Frame Format
**Problem**: ImageProxy provides YUV data in NV21 or YUV_420_888 format  
**Solution**: Detect format and convert if needed:
```kotlin
val planes = imageProxy.planes
val y = planes[0].buffer
val u = planes[1].buffer  
val v = planes[2].buffer
// Copy to contiguous buffer and pass to MediaCodec
```

### Challenge 2: Frame Timing
**Problem**: Must maintain correct presentation timestamps for smooth playback  
**Solution**: Use `imageProxy.image.timestamp` for each frame:
```kotlin
val pts = imageProxy.image.timestamp
mediaCodec.queueInputBuffer(index, 0, size, pts, flags)
```

### Challenge 3: Memory Management
**Problem**: ImageProxy must be closed after use to free resources  
**Current**: Auto-closed in ImageAnalysis callback (line 119)  
**Warning**: Don't reuse ImageProxy outside the callback

### Challenge 4: Buffer Configuration
**Problem**: MediaCodec needs different setup for buffer vs Surface mode  
**Solution**: 
```kotlin
// Buffer mode instead of Surface mode:
val format = MediaFormat.createVideoFormat(codecName, width, height)
format.setInteger(MediaFormat.KEY_COLOR_FORMAT, 
    MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Planar)
mediaCodec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
// DON'T call createInputSurface()
```

## Testing Strategy
1. **Build test**: `flutter run` should compile without errors
2. **Preview test**: Camera preview should be ALWAYS visible (no pausing)
3. **Encoding test**: Check logcat for "Frame #N" messages (frames being encoded)
4. **Bitrate test**: Stats should show > 0 Mb/s during streaming
5. **SRT test** (later): Video should appear in OBS after SRT sending implemented

## Git Status
**Branch**: Current feature branch  
**Modified files**:
- `plugins/station_broadcast/android/src/main/kotlin/tv/stationcast/station_broadcast/CameraXManager.kt` ✅
- `plugins/station_broadcast/android/build.gradle.kts` ✅ (added camera-video)
- `plugins/station_broadcast/android/src/main/kotlin/tv/stationcast/station_broadcast/BroadcastEngineNew.kt` ⚠️ (needs frame callback)
- `plugins/station_broadcast/android/src/main/kotlin/tv/stationcast/station_broadcast/VideoEncoder.kt` ⚠️ (needs frame encoding)

## Next Steps for Continuation
1. Refactor VideoEncoder.kt to accept raw frames (most critical)
2. Wire up frame callback in BroadcastEngineNew
3. Test preview stays active during streaming
4. Verify frames encode (check logcat logs)
5. Implement SRT sending (Phase 2)

## Resources
- CameraX ImageAnalysis: https://developer.android.com/media/camera/architecture
- MediaCodec buffer mode: https://developer.android.com/reference/android/media/MediaCodec
- YUV formats: NV21 (most common), YUV_420_888 (standard)
