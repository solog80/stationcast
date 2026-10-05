# StationCast WebRTC-to-NDI Bridge (Go Edition)

An enterprise-grade, ultra-low latency **OvenMediaEngine (OME) WebRTC to NDI Bridge** written in **Go** with macOS VideoToolbox hardware acceleration and pure Go Windows cross-compilation support for **Multi-Stream Bridging** of live contributors.

Designed for live television broadcasts, remote field reporting, and multi-camera live production environments (StationCast).

---

## 🌟 Key Features

- **📡 Multi-Stream Contributor Bridging**: Simultaneously decode and bridge multiple remote publisher channels (e.g. `field1`, `field2`, `field3`, `studio_feed`) to individual native NDI streams in a single process.
- **💻 Cross-Platform (macOS & Windows)**: Runs natively on macOS (with Cgo VideoToolbox HW acceleration) and Windows 64-bit (via pure Go VP8 decoder & NDI DLL dynamic loading).
- **🖥️ System Tray Application**: System tray icon and menu with live status monitoring, one-click Web Dashboard launcher, global Force Keyframe (PLI) trigger, and Auto-Start management.
- **🚀 Auto-Start at Boot/Login**: Native boot persistence via macOS `LaunchAgent` plist and Windows HKCU `Run` Registry keys.
- **🎨 SMPTE Color Bars Standby System**: When disconnected or waiting for field reporters to go live, each channel outputs high-definition SMPTE Color Bars (procedural or loaded from `smpte_color_bars.webp`) so NDI receivers (OBS, vMix, TriCaster) never lose video signal.
- **⚡ Instant Auto-Reconnection (<500ms)**: Handles mobile publisher disconnects, network drops, and device orientation switches (Portrait $\leftrightarrow$ Landscape) with sub-second automatic ICE teardown and reconnection per channel.
- **🛡️ Panic & Exception Safety**: Go `recover()` protection wrapping decoder pipelines prevents app crashes on dynamic resolution switches.
- **🎛️ Multi-Channel HTTP Web Control Dashboard**: Web Dashboard (`http://localhost:7890`) with dynamic port fallback (`7890-7910`), live resolution monitoring, real-time FPS counters, channel management, and per-stream Force Keyframe (PLI) requests.
- **⚡ Production Log Performance**: Dual-tier logging (`enable_logs` and `verbose_logs`) allows muting per-frame progress logs to run at zero CPU I/O overhead during high frame rate broadcasts.

---

## 🏗️ Architecture & How It Functions

```
[ Field Reporter 1 ] --(WebRTC)--> [ OvenMediaEngine ]
[ Field Reporter 2 ] --(WebRTC)-->        │
                                   (WebSocket Signaling)
                                          ▼
                             [ StationCast NDI Bridge ]
                             ┌────────────┴────────────┐
                     (Channel 1)                   (Channel 2)
                 (VP8 Decoder Pipeline)       (VP8 Decoder Pipeline)
                          │                             │
               [ NDI: Field_1_StationCast ]   [ NDI: Field_2_StationCast ]
                          │                             │
                          └──────────────┬──────────────┘
                                         ▼
                             [ OBS / vMix / TriCaster ]
```

---

## 🎛️ Configuration (`ndi_bridge_config.json`)

```json
{
  "host": "75.119.149.43",
  "streams": [
    {
      "stream": "field1",
      "ndi_name": "Field_1_StationCast",
      "standby_image": "smpte_color_bars.webp"
    },
    {
      "stream": "field2",
      "ndi_name": "Field_2_StationCast",
      "standby_image": "smpte_color_bars.webp"
    }
  ],
  "enable_logs": true,
  "verbose_logs": false
}
```

| Field | Description | Default |
|---|---|---|
| `host` | OvenMediaEngine server IP address | `75.119.149.43` |
| `streams` | Array of contributor stream channel objects | `[ field1, field2 ]` |
| `stream` | Stream key name published on OME | `field1` |
| `ndi_name` | Published NDI output source name on local network | `Field_1_StationCast` |
| `standby_image` | Path to standby image file | `smpte_color_bars.webp` |
| `enable_logs` | Enable console and dashboard logging | `true` |
| `verbose_logs` | Enable per-frame keyframe/counter logs | `false` |

---

## 🚀 Building & Running

### Prerequisites

#### macOS
- Go 1.26+
- NDI SDK for macOS installed (`libndi.dylib`)
- FFmpeg libraries (`libavcodec`, `libswscale`, `libavutil`) installed via Homebrew:
  ```bash
  brew install ffmpeg
  ```

#### Windows
- Go 1.26+
- NDI 5 / NDI 6 Core Runtime installed (`Processing.NDI.Lib.x64.dll` in system PATH or application directory).

---

### 🔨 Building

#### Build for macOS (Native App Bundle)
```bash
./build_mac_app.sh
```
Or build standard binary:
```bash
go build -v -o StationCast_NDI_Bridge .
```

#### Cross-Compile / Build for Windows 64-bit
Run the included build script:
```bash
./build_win.sh
```
Or execute manual cross-compilation command:
```bash
CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -v -ldflags="-s -w -H windowsgui" -o StationCast_NDI_Bridge.exe .
```

---

### 🏃 Running

#### macOS
Double click `StationCast NDI Bridge.app` or run via CLI:
```bash
./StationCast_NDI_Bridge
```

#### Windows
Double click `StationCast_NDI_Bridge.exe`. It launches cleanly into the system tray without popping up a console window. Access options and status via the system tray menu icon.
