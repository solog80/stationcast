# StationCast

Field-contribution broadcaster for TV stations, built with Flutter.

- **Publish** camera + microphone live over **SRT** (caller mode, with streamid /
  passphrase / latency) or **RTMP** to vMix, OBS, MediaMTX or hardware decoders.
- **Return feed**: a floating, draggable in-app window plays the station's
  program output over SRT (muted by default to prevent echo).
- Broadcast controls: ON AIR tally + timer, link health (bitrate / RTT / drops),
  camera flip, torch, zoom, mic mute, audio device pick, reconnect with backoff,
  keep-screen-awake, dark control-room UI.

## Architecture

| Layer | What |
|---|---|
| `plugins/station_broadcast/` | Local Flutter plugin: the broadcast engine. Android = [StreamPack 3.1.2](https://github.com/ThibaultBee/StreamPack) (Kotlin), iOS = [HaishinKit 2.2.5](https://github.com/HaishinKit/HaishinKit.swift) + SRTHaishinKit (Swift, via SPM). Exposes a MethodChannel, two EventChannels (state events, 1 Hz stats) and a native camera-preview PlatformView. |
| `lib/broadcast/` | Riverpod state: `BroadcastController` (go-live / stop / reconnect state machine), providers for stats, presets, encoder and return-feed settings. |
| `lib/return_feed/` | `ReturnFeedPlayer` abstraction with two backends: media_kit (libmpv) and VLC (libVLC). `auto` starts with media_kit and falls back to VLC if SRT playback fails — libVLC has the most reliable `srt://` support. |
| `lib/ui/` | Broadcast screen (full-bleed native preview + overlays), floating return-feed window, settings. |

The native library owns the camera (required for hardware-encoded publish), so
the viewfinder is the engine's own preview view embedded as a PlatformView —
not the Flutter `camera` plugin.

## Requirements

- Flutter 3.44+, with Swift Package Manager enabled for iOS:
  `flutter config --enable-swift-package-manager`
- Android: minSdk 24. iOS: 15.0+.
- Real devices for anything camera/SRT related (simulators have no camera).

> **Note (exFAT drives):** if the project lives on an exFAT volume, macOS
> litters it with `._*` AppleDouble files that break `flutter test`/builds.
> Run `find . -name "._*" -delete` (or `dot_clean -m .`) when a build fails
> with a cryptic file error. Moving the project to the internal disk avoids
> this entirely.

## Local end-to-end test rig (MediaMTX)

[MediaMTX](https://github.com/bluenviron/mediamtx) simulates both the station
ingest and the return feed with one binary:

```bash
brew install mediamtx
mediamtx        # SRT listens on :8890
```

Phone and Mac must be on the same Wi-Fi. Allow mediamtx through the macOS
firewall (SRT is UDP). Find your Mac's IP with `ipconfig getifaddr en0`.

### 1. Publish path (phone → station)

In the app: Settings → Add destination →
host `MAC_IP`, port `8890`, stream ID `publish:cam`, latency `200`.
Hit **GO LIVE**, then verify on the Mac:

```bash
ffplay -fflags nobuffer "srt://localhost:8890?streamid=read:cam"
```

Or add an OBS Media Source / vMix SRT input with that URL for receiver realism.

### 2. Return path (station → phone)

Send a test program feed to MediaMTX:

```bash
ffmpeg -re -f lavfi -i testsrc2=size=1280x720:rate=30 -f lavfi -i sine \
  -c:v libx264 -preset veryfast -tune zerolatency -b:v 2M -c:a aac \
  -f mpegts "srt://localhost:8890?streamid=publish:ret"
```

In the app: Settings → Return feed → URL
`srt://MAC_IP:8890?streamid=read:ret`. Toggle the picture-in-picture button on
the broadcast screen. The window is draggable, snaps to corners, and starts
muted.

### 3. The real acceptance test

Run both directions at once for 15+ minutes; watch thermals, A/V sync, and the
health overlay. Then drill failures: kill mediamtx mid-stream (expect
RECONNECTING → recover after restart), toggle Wi-Fi, use a wrong passphrase
(expect a clear error), lock the screen on Android (the foreground service
keeps the stream up).

### Encrypted SRT

In `mediamtx.yml`:

```yaml
paths:
  cam:
    srtPublishPassphrase: "0123456789"
    srtReadPassphrase: "0123456789"
```

Set the same passphrase in the app's destination preset.

## Known limitations (v1)

- Audio level meters render only when the engine reports levels; neither
  native engine exposes a frame tap yet (planned: custom audio source tap).
- iOS pauses camera capture in the background — keep the app foregrounded
  while live (the screen stays awake automatically).
- Adaptive bitrate is not wired up yet; StreamPack ships an SRT bitrate
  regulator, iOS needs a custom one on `SRTConnection.performanceData`.
- CocoaPods trunk only has HaishinKit 2.0.x; SPM (pinned 2.2.5) is the
  supported iOS integration.
- Local MP4 recording backup, WHIP publish and WHEP return are planned (M2/M3).
