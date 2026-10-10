# OpenPocketCine Architecture Analysis & Recommendations for Station Cast

After analyzing the source code of [OpenPocketCine](https://github.com/erik-sutton95/OpenPocketCine), we identified several key solutions that directly solve the **autofocus** issues, **SurfaceView preview glitches**, and **thermal/heating** issues in **Station Cast**.

---

## 1. SurfaceView Glitches & Thermal / Heating Optimization

### A. Remove Display Refresh Rate Lock (`setFrameRate(24.0f)`)
- **Current Issue in Station Cast** (`CameraPreviewPlatformView.kt:96`):
  ```kotlin
  surface.setFrameRate(24.0f, android.view.Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE)
  ```
  Calling `setFrameRate(24.0f)` forces Android's SurfaceFlinger and display driver to continuously switch/throttle display composition rates to 24 Hz while Flutter UI runs at 60 Hz / 120 Hz. This causes severe compositor thrashing, display tearing, micro-stutter, and **increased CPU/GPU heat generation**.
- **OpenPocketCine Solution**: Preview surfaces run unlocked at native display refresh rates (60 Hz / 120 Hz). Display rate locks are not forced onto preview SurfaceViews.

### B. Prevent Android 14+ (API 34) Surface Destruction (`setSurfaceLifecycle`)
- **Current Issue in Station Cast**: When opening dialogs, sheets, or settings overlays over the camera view, Android 14+ destroys the underlying `SurfaceView` window. Upon closing the overlay, the camera preview turns into a black well because no new GOP/keyframe is emitted immediately.
- **OpenPocketCine Solution** (`LiveViewScreen.kt:1115`):
  ```kotlin
  if (Build.VERSION.SDK_INT >= 34) {
      setSurfaceLifecycle(SurfaceView.SURFACE_LIFECYCLE_FOLLOWS_ATTACHMENT)
  }
  ```
  This forces Android to keep the Surface attached and valid even when covered by UI overlays, avoiding constant surface teardown/re-creation overhead.

### C. Fix SurfaceView Layer Stacking & Visibility Toggling Flashes
- **Current Issue in Station Cast** (`CameraPreviewPlatformView.kt`):
  `CameraPreviewPlatformView` stacks two `SurfaceView` instances (`SurfaceViewRenderer` for WebRTC and `streampackSurfaceView` for StreamPack) and toggles between `View.GONE` and `View.VISIBLE`. On Android, toggling `SurfaceView.visibility` causes WindowManager to destroy and recreate hardware surface layers, causing black screen flashes and unnecessary allocation churn.
- **OpenPocketCine Solution**: 
  1. Use explicit Z-ordering control: `setZOrderMediaOverlay(true)` or `setZOrderOnTop(false)`.
  2. Use single-surface rendering management or controlled Z-layering rather than toggling `View.GONE` on multiple native SurfaceViews.

### D. Prevent Multi-Touch Gesture Splitting (`unsplitMotionEvents`)
- **Current Issue in Station Cast**: Pinch-to-zoom gestures over the preview can break when Android splits pointer events between the native SurfaceView child and parent Flutter views.
- **OpenPocketCine Solution** (`LiveViewScreen.kt:1164`):
  ```kotlin
  private fun View.unsplitMotionEvents() {
      var walk: View? = this
      while (walk != null) {
          (walk as? ViewGroup)?.isMotionEventSplittingEnabled = false
          walk = walk.parent as? View
      }
  }
  ```

---

## 2. Thermal Throttling & Power Management

- **PowerManager Thermal Monitoring**:
  OpenPocketCine reads `PowerManager.currentThermalStatus` (`THERMAL_STATUS_MODERATE`, `THERMAL_STATUS_SEVERE`, `THERMAL_STATUS_CRITICAL`).
- **Adaptive Calculation Intervals**:
  Background scope calculations (histogram, audio meters, overlay analysis) apply a thermal multiplier (`x3` / `x5` interval backoff) when the device heats up, keeping UI responsive without overheating the SoC.

---

## 3. Autofocus & Tap-to-Focus Improvements

### A. Viewport-Fitted Coordinate Mapping (`WatcherFocusPoint`)
- **Current Issue in Station Cast** (`BroadcastEngine.kt:560`):
  `camera2SetFocusPoint(x, y)` receives normalized coordinates (0..1) from Flutter and directly scales them to sensor space:
  ```kotlin
  val cx = (x.coerceIn(0f, 1f) * span).toInt()
  val cy = (y.coerceIn(0f, 1f) * span).toInt()
  ```
  This ignores aspect ratio letterboxing, pillarboxing, camera mirroring, and sensor orientation. If a user taps on letterbox padding, invalid coordinates are sent to Camera2.
- **OpenPocketCine Solution** (`WatcherFocusPoint.swift`):
  Transform tap coordinates relative to the *fitted video bounding box*, excluding letterbox bars, and account for sensor mirroring:
  ```swift
  let nx = (x - letterboxX) / videoWidth
  let ny = (y - letterboxY) / videoHeight
  let mappedX = mirrored ? (1.0 - nx) : nx
  ```

### B. Recenter / Reset Focus Mode Lifecycle
- **Current Issue in Station Cast**:
  Once tap-to-focus triggers `CONTROL_AF_MODE_AUTO`, the camera remains in single-shot AF mode indefinitely. It never automatically returns to continuous video autofocus (`CONTROL_AF_MODE_CONTINUOUS_VIDEO`).
- **OpenPocketCine Solution**:
  1. Maintain a focus reset trigger (button or timer).
  2. Reset focus mode back to `CONTROL_AF_MODE_CONTINUOUS_VIDEO` and clear metering rectangles (`MeteringRectangle(0, 0, 0, 0, 0)`) when recentered.
  3. Support AF trigger start (`CONTROL_AF_TRIGGER_START`) during tap-to-focus and hold focus state until AF lock completes.

---

## Summary of Actionable Steps for Station Cast

| Component | Recommended Action | Source File in Station Cast |
| :--- | :--- | :--- |
| **Surface Refresh Rate & Heating** | Remove `surface.setFrameRate(24.0f)` on preview surfaces. | `plugins/station_broadcast/.../CameraPreviewPlatformView.kt` |
| **Android 14 Surface Lifecycle** | Add `setSurfaceLifecycle(SURFACE_LIFECYCLE_FOLLOWS_ATTACHMENT)` for API 34+. | `plugins/station_broadcast/.../CameraPreviewPlatformView.kt` |
| **Surface Visibility** | Replace `View.GONE` toggling with Z-order layering or unified surface rendering. | `plugins/station_broadcast/.../CameraPreviewPlatformView.kt` |
| **Touch Event Handling** | Disable motion event splitting on preview container. | `plugins/station_broadcast/.../CameraPreviewPlatformView.kt` |
| **Tap-to-Focus Geometry** | Implement fitted-video coordinate mapping and out-of-bounds rejection. | `lib/ui/widgets/camera_controls.dart` & `BroadcastEngine.kt` |
| **Focus Mode Reset** | Add continuous AF auto-reset / recenter trigger after tap-to-focus. | `plugins/station_broadcast/.../BroadcastEngine.kt` |
