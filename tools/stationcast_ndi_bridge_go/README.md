# StationCast WebRTC-to-NDI Bridge (Go Edition)

An enterprise-grade, ultra-low latency **OvenMediaEngine (OME) WebRTC to NDI Bridge** written in **Go** with Cgo bindings for **macOS VideoToolbox hardware acceleration**.

Designed for live television broadcasts, remote field reporting, and multi-camera live production environments (StationCast).

---

## 🌟 Key Features

- **🚀 macOS Hardware Acceleration**: Hardware-accelerated VP8 video decoding via VideoToolbox (`AV_HWDEVICE_TYPE_VIDEOTOOLBOX`) + FFmpeg `libavcodec` / `libswscale`.
- **🎨 SMPTE Color Bars Standby System**: When disconnected or waiting for field reporters to go live, the bridge outputs high-definition SMPTE Color Bars (loaded from `smpte_color_bars.webp` or generated procedurally in code) so NDI receivers (OBS, vMix, TriCaster) never lose video signal.
- **⚡ Instant Auto-Reconnection (<500ms)**: Handles mobile publisher disconnects, network drops, and device orientation switches (Portrait $\leftrightarrow$ Landscape) with sub-second automatic ICE teardown and reconnection.
- **🛡️ Panic & Exception Safety**: Go `recover()` protection wrapping the Cgo hardware decoder pipeline prevents app crashes on dynamic video resolution changes.
- **🎛️ HTTP Web Control Dashboard**: Auto-launching Web Dashboard (`http://localhost:7890`) with dynamic port fallback (`7890-7910`), live resolution monitoring, real-time FPS counter, and manual Keyframe PLI requests.
- **⚡ Production Log Performance**: Dual-tier logging (`enable_logs` and `verbose_logs`) allows muting per-frame progress logs to run at zero CPU I/O overhead during high frame rate broadcasts.

---

## 🏗️ Architecture & How It Functions

```
[ Mobile / Reporter ] --(WebRTC VP8)--> [ OvenMediaEngine (OME) ]
                                                │
                                       (WebSocket Signaling)
                                                ▼
                                   [ StationCast NDI Bridge ]
                                                │
                                    (VideoToolbox HW Decoder)
                                                ▼
                                    (BGRA Video Frame Buffer)
                                                │
                                   [ Native NDI Output Stream ]
                                                ▼
                                   [ OBS / vMix / TriCaster ]
```

### 1. WebRTC & Signaling Layer (`main.go`)
- Establishes a WebSocket connection to `ws://<OME_HOST>:3333/app/<STREAM_NAME>`.
- Requests SDP offers from OvenMediaEngine and creates a Pion WebRTC (`github.com/pion/webrtc/v3`) `PeerConnection`.
- Dynamically gathers local ICE candidates and exchanges remote candidates with OME.

### 2. Hardware Video Decoding Pipeline (`main.go`)
- RTP video packets (`VP8`) are collected and ordered using `pion/webrtc/pkg/media/samplebuilder`.
- Frames are passed to a Cgo wrapper wrapping FFmpeg `libavcodec` with Apple Silicon **VideoToolbox** hardware context.
- Decoded frames are converted to raw `BGRA` format via `libswscale` and passed directly into shared memory.

### 3. Standby & Color Bars Generator (`ndi.go`)
- A background Go routine (`runStandbyLoop`) continuously checks time since the last live video frame.
- If live video stops or drops for >500ms, the bridge automatically switches to streaming pre-rendered SMPTE Color Bars (`1280x720` BGRA at 30 FPS).
- If the `smpte_color_bars.webp` image file is missing, a built-in 75% SMPTE color bar procedural generator takes over automatically.

### 4. NDI Output Layer (`ndi.go`)
- Dynamically loads `libndi.dylib` at runtime via `dlopen`.
- Publishes native uncompressed video streams to the local network using `NDIlib_send_send_video_v2`.

---

## 🎛️ Web Dashboard & API Endpoints

Access the control interface in any web browser at `http://localhost:7890`:

- **Live Indicators**: Active resolution (`960x540`, `1280x720`, `1920x1080`), real-time FPS counter, total rendered frame count.
- **🚀 Force Keyframe (PLI)**: Sends an RTCP Picture Loss Indication to the publisher to immediately clear video artifacts or freeze frames.
- **🎨 Reload Color Bars**: Dynamically updates the standby frame image path.
- **Logging Controls**: Toggle system logs and verbose frame logging on/off.

---

## ⚙️ Configuration (`ndi_bridge_config.json`)

```json
{
  "host": "75.119.149.43",
  "stream": "field1",
  "ndi_name": "Field1StationCast",
  "standby_image": "smpte_color_bars.webp",
  "enable_logs": true,
  "verbose_logs": false
}
```

| Field | Description | Default |
|---|---|---|
| `host` | OvenMediaEngine server IP address | `75.119.149.43` |
| `stream` | Stream key name published on OME | `field1` |
| `ndi_name` | Published NDI output source name | `Field1StationCast` |
| `standby_image` | Path to standby image file | `smpte_color_bars.webp` |
| `enable_logs` | Enable console and dashboard logging | `true` |
| `verbose_logs` | Enable per-frame keyframe/counter logs | `false` |

---

## 🚀 Building & Running

### Prerequisites
- macOS (Apple Silicon or Intel)
- Go 1.26+
- NDI SDK for macOS installed (`libndi.dylib`)
- FFmpeg libraries (`libavcodec`, `libswscale`, `libavutil`) installed via Homebrew:
  ```bash
  brew install ffmpeg
  ```

### Build Command
```bash
go build -v -o StationCast_NDI_Bridge .
```

### Launch Command
```bash
./StationCast_NDI_Bridge
```

---

## 🔮 Future Improvements & Roadmap

1. **🔊 Opus Audio Decoding to NDI Audio**:
   - Integrate Opus audio decoding to output 48kHz stereo float32 PCM audio alongside NDI video.
2. **🎬 Multi-Codec Hardware Acceleration**:
   - Add hardware decoding support for H.264, HEVC (H.265), and AV1 streams alongside VP8.
3. **📡 Multi-Stream Bridging**:
   - Enable multi-channel stream bridging in a single process (e.g. `field1`, `field2`, `studio_feed` simultaneously).
4. **⏺️ Local Stream Recording / ISO Recording**:
   - Option to record incoming raw live feeds to MP4/MOV files on local storage while bridging to NDI.
