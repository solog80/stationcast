# OvenMediaEngine WebRTC (WHEP) to NDI Bridge

This tool connects to an **OvenMediaEngine (OME)** WebRTC stream and broadcasts it as a local **NDI Stream** on your local network. 

Both **vMix** and **OBS Studio** (with the `obs-ndi` plugin) will detect this NDI stream natively with **sub-second latency (<0.2s)**, embedded video, and 48kHz audio.

---

## 🚀 Quick Start (macOS & Windows)

### 1. Prerequisites
- Python 3.9 or higher
- [Free NDI Runtime](https://ndi.video/tools/) installed on your computer.

### 2. Installation

```bash
cd tools/ome_ndi_bridge
pip install -r requirements.txt
```

### 3. Run the Bridge

To start bridging the `field1` stream into an NDI stream named `Field 1 (StationCast)`:

```bash
python bridge.py --url "http://75.119.149.43:3333/app/field1?direction=whep" --name "Field 1 (StationCast)"
```

---

## 📺 How to Receive in vMix

1. Open **vMix**.
2. Click **Add Input** $\rightarrow$ **NDI / Desktop Capture**.
3. Select **`Field 1 (StationCast)`** under local NDI sources.
4. Click **OK**.
5. **Done!** You now have sub-second WebRTC video + audio inside vMix.

---

## 🎥 How to Receive in OBS Studio

1. Ensure the [obs-ndi plugin](https://github.com/obs-ndi/obs-ndi) is installed.
2. In OBS, click **+** under **Sources** $\rightarrow$ **NDI Source**.
3. Select **`Field 1 (StationCast)`** from the **Source name** drop-down.
4. Click **OK**.

---

## ⚙️ Command Line Options

| Argument | Default | Description |
| :--- | :--- | :--- |
| `--url` | `http://75.119.149.43:3333/app/field1?direction=whep` | OvenMediaEngine WHEP endpoint |
| `--name` | `Field 1 (StationCast)` | NDI stream name published to the local network |
