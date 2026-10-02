#!/usr/bin/env python3
"""
StationCast OME to NDI Bridge - Web Desktop App
Zero-dependency 1-click application for Windows & macOS that receives
OvenMediaEngine WebRTC streams and publishes them as local NDI sources.
"""

import asyncio
import json
import logging
import os
import sys
import threading
import webbrowser
from http.server import HTTPServer, BaseHTTPRequestHandler

import numpy as np
import aiohttp
from aiortc import RTCPeerConnection, RTCSessionDescription
import NDIlib as ndi

PORT = 7890
CONFIG_FILE = "ndi_bridge_config.json"

logging.basicConfig(level=logging.INFO, format="[%(asctime)s] %(levelname)s: %(message)s")
logger = logging.getLogger("ome_ndi_bridge")

# Shared State
state = {
    "status": "Disconnected",
    "status_color": "red",
    "host": "75.119.149.43",
    "stream": "field1",
    "ndi_name": "Field 1 - StationCast",
    "logs": []
}

def add_log(msg):
    logger.info(msg)
    state["logs"].append(msg)
    if len(state["logs"]) > 100:
        state["logs"].pop(0)

# Load saved config
if os.path.exists(CONFIG_FILE):
    try:
        with open(CONFIG_FILE, "r") as f:
            cfg = json.load(f)
            state["host"] = cfg.get("host", state["host"])
            state["stream"] = cfg.get("stream", state["stream"])
            state["ndi_name"] = cfg.get("ndi_name", state["ndi_name"])
    except Exception:
        pass

def save_config():
    try:
        with open(CONFIG_FILE, "w") as f:
            json.dump({
                "host": state["host"],
                "stream": state["stream"],
                "ndi_name": state["ndi_name"]
            }, f)
    except Exception:
        pass


class OmeNdiBridgeEngine:
    def __init__(self, whep_url, ndi_name):
        self.whep_url = whep_url
        self.ndi_name = ndi_name
        self.running = False
        self.pc = None
        self.ndi_send = None

    def start(self):
        self.running = True
        threading.Thread(target=self._run_loop, daemon=True).start()

    def stop(self):
        self.running = False

    def _run_loop(self):
        asyncio.run(self._async_run())

    async def _async_run(self):
        state["status"] = "Initializing NDI..."
        state["status_color"] = "yellow"
        add_log("Initializing NDI SDK...")

        if not ndi.initialize():
            add_log("ERROR: Failed to initialize NDI SDK.")
            state["status"] = "NDI Init Failed"
            state["status_color"] = "red"
            return

        clean_name = self.ndi_name.replace("(", "").replace(")", "").replace(" ", "_")
        send_settings = ndi.SendCreate()
        send_settings.ndi_name = clean_name or "Field_1_StationCast"
        self.ndi_send = ndi.send_create(send_settings)
        if self.ndi_send is None:
            add_log("ERROR: Failed to create NDI send instance.")
            state["status"] = "NDI Create Failed"
            state["status_color"] = "red"
            return

        add_log(f"NDI Stream published as '{self.ndi_name}'")

        while self.running:
            self.pc = RTCPeerConnection()

            @self.pc.on("track")
            def on_track(track):
                add_log(f"Receiving WebRTC Track: {track.kind}")
                if track.kind == "video":
                    asyncio.create_task(self._handle_video(track))
                elif track.kind == "audio":
                    asyncio.create_task(self._handle_audio(track))

            host = state.get("host", "75.119.149.43")
            stream = state.get("stream", "field1")

            connected = False
            state["status"] = "Connecting..."
            state["status_color"] = "yellow"

            # Method 1: Try OvenMediaEngine Native WebSocket Signalling (OvenPlayer Protocol)
            ws_url = f"ws://{host}:3333/app/{stream}"
            add_log(f"Connecting to OME WebSocket: {ws_url}")
            
            try:
                async with aiohttp.ClientSession() as session:
                    async with session.ws_connect(ws_url, timeout=5) as ws:
                        await ws.send_json({"command": "request_offer"})

                        async for msg in ws:
                            if not self.running:
                                break
                            if msg.type == aiohttp.WSMsgType.TEXT:
                                data = json.loads(msg.data)
                                error_code = data.get("code")
                                cmd = data.get("command")

                                if error_code == 404 or "Cannot create offer" in str(data):
                                    add_log(f"⚠️ Live stream '{stream}' is not active on OME server yet.")
                                    break

                                if cmd == "offer":
                                    sdp_data = data.get("sdp")
                                    offer_sdp = sdp_data.get("sdp") if isinstance(sdp_data, dict) else str(sdp_data)
                                    candidates = data.get("candidates", [])

                                    cand_lines = [c["candidate"] if c["candidate"].startswith("a=") else "a=" + c["candidate"] for c in candidates if c.get("candidate")]
                                    full_sdp = offer_sdp.strip() + "\r\n" + "\r\n".join(cand_lines) + "\r\n"

                                    offer = RTCSessionDescription(sdp=full_sdp, type="offer")
                                    await self.pc.setRemoteDescription(offer)

                                    answer = await self.pc.createAnswer()
                                    await self.pc.setLocalDescription(answer)

                                    # Inject PLI/FIR RTCP feedback to force OME keyframe generation
                                    answer_sdp = self.pc.localDescription.sdp
                                    lines = answer_sdp.splitlines()
                                    new_lines = []
                                    for line in lines:
                                        new_lines.append(line)
                                        if line.startswith("a=rtpmap:"):
                                            pt = line.split()[0].split(":")[1]
                                            new_lines.append(f"a=rtcp-fb:{pt} nack pli")
                                            new_lines.append(f"a=rtcp-fb:{pt} ccm fir")
                                    final_sdp = "\r\n".join(new_lines) + "\r\n"

                                    reply = {
                                        "command": "answer",
                                        "id": data.get("id"),
                                        "peer_id": data.get("peer_id"),
                                        "sdp": {
                                            "type": "answer",
                                            "sdp": final_sdp
                                        }
                                    }
                                    if reply["id"] is None: del reply["id"]
                                    if reply["peer_id"] is None: del reply["peer_id"]

                                    await ws.send_json(reply)
                                    add_log("CONNECTED via OME WebSocket! Streaming live WebRTC media -> NDI output...")
                                    state["status"] = "Streaming Live NDI"
                                    state["status_color"] = "green"
                                    connected = True

                                    async for post_msg in ws:
                                        if not self.running:
                                            break
                                        if post_msg.type == aiohttp.WSMsgType.TEXT:
                                            pdata = json.loads(post_msg.data)
                                            if pdata.get("code") == 400 or pdata.get("command") == "error":
                                                add_log(f"OME Session ended: {pdata}")
                                                connected = False
                                                break
                                    break
                                elif cmd == "error":
                                    add_log(f"OME WebSocket Error: {data.get('message')}")
                                    break
            except Exception as ws_err:
                add_log(f"WebSocket attempt failed: {ws_err}")

            if connected:
                while self.running and connected:
                    await asyncio.sleep(1)
            else:
                if self.running:
                    add_log("Waiting for field reporter to go live... Retrying in 3 seconds.")
                    state["status"] = "Waiting for Stream..."
                    state["status_color"] = "yellow"
                    await self._cleanup_pc()
                    await asyncio.sleep(3)

        await self._cleanup()

    async def _cleanup_pc(self):
        if self.pc:
            try:
                await self.pc.close()
            except Exception:
                pass
            self.pc = None

    async def _handle_video(self, track):
        video_frame = ndi.VideoFrameV2()
        video_frame.FourCC = ndi.FOURCC_VIDEO_TYPE_RGBA
        while self.running:
            try:
                frame = await track.recv()
                img_rgba = frame.to_ndarray(format="rgba")
                h, w, _ = img_rgba.shape

                video_frame.xres = w
                video_frame.yres = h
                video_frame.data = img_rgba
                video_frame.line_stride_in_bytes = img_rgba.strides[0]
                ndi.send_send_video_v2(self.ndi_send, video_frame)
            except Exception:
                break

    async def _handle_audio(self, track):
        audio_frame = ndi.AudioFrameV2()
        while self.running:
            try:
                frame = await track.recv()
                pcm = frame.to_ndarray()
                audio_frame.sample_rate = frame.sample_rate
                audio_frame.no_channels = len(frame.layout.channels)
                audio_frame.no_samples = frame.samples
                audio_frame.channel_stride_in_bytes = frame.samples * 4
                float_data = pcm.astype(np.float32) / 32768.0 if pcm.dtype == np.int16 else pcm.astype(np.float32)
                audio_frame.data = float_data
                ndi.send_send_audio_v2(self.ndi_send, audio_frame)
            except Exception:
                break

    async def _cleanup(self):
        await self._cleanup_pc()
        if self.ndi_send:
            ndi.send_destroy(self.ndi_send)
            self.ndi_send = None
        ndi.destroy()
        state["status"] = "Disconnected"
        state["status_color"] = "red"
        add_log("NDI Bridge stopped.")

active_engine = None

HTML_PAGE = """<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>StationCast OME to NDI Bridge</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #181825; color: #CDD6F4; margin: 0; padding: 30px; }
    .card { background: #1E1E2E; border-radius: 12px; padding: 25px; max-width: 500px; margin: 0 auto; box-shadow: 0 10px 30px rgba(0,0,0,0.5); }
    h2 { margin-top: 0; color: #89B4FA; font-size: 20px; display: flex; align-items: center; justify-content: space-between; }
    .status-badge { font-size: 13px; padding: 4px 10px; border-radius: 20px; color: #11111B; font-weight: bold; }
    .bg-green { background: #A6E3A1; }
    .bg-yellow { background: #F9E2AF; }
    .bg-red { background: #F38BA8; }
    label { display: block; margin-top: 15px; font-size: 13px; color: #BAC2DE; }
    input { width: 100%; box-sizing: border-box; padding: 10px; border-radius: 6px; border: 1px solid #45475A; background: #313244; color: #FFF; font-size: 14px; margin-top: 5px; }
    .btn-group { margin-top: 20px; display: flex; gap: 10px; }
    button { flex: 1; padding: 12px; border: none; border-radius: 6px; font-weight: bold; cursor: pointer; font-size: 14px; }
    .btn-start { background: #A6E3A1; color: #11111B; }
    .btn-stop { background: #F38BA8; color: #11111B; }
    .logs { background: #11111B; border-radius: 6px; padding: 10px; height: 120px; overflow-y: auto; font-family: monospace; font-size: 11px; color: #A6ADC8; margin-top: 20px; white-space: pre-wrap; }
  </style>
</head>
<body>
  <div class="card">
    <h2>
      StationCast NDI Bridge
      <span id="badge" class="status-badge bg-red">Disconnected</span>
    </h2>
    <label>OME Server Host / IP</label>
    <input id="host" value="75.119.149.43">
    
    <label>Stream Name</label>
    <input id="stream" value="field1">
    
    <label>NDI Output Stream Name</label>
    <input id="ndi_name" value="Field 1 (StationCast)">
    
    <div class="btn-group">
      <button class="btn-start" onclick="startStream()">▶ START NDI STREAM</button>
      <button class="btn-stop" onclick="stopStream()">⏹ STOP</button>
    </div>
    
    <div class="logs" id="logs">Waiting for user action...</div>
  </div>

  <script>
    async function update() {
      try {
        const res = await fetch('/api/state');
        const data = await res.json();
        document.getElementById('host').value = data.host;
        document.getElementById('stream').value = data.stream;
        document.getElementById('ndi_name').value = data.ndi_name;
        
        const badge = document.getElementById('badge');
        badge.innerText = data.status;
        badge.className = 'status-badge bg-' + data.status_color;
        
        const logsDiv = document.getElementById('logs');
        logsDiv.innerText = data.logs.join('\\n');
        logsDiv.scrollTop = logsDiv.scrollHeight;
      } catch(e) {}
    }

    async function startStream() {
      const host = document.getElementById('host').value;
      const stream = document.getElementById('stream').value;
      const ndi_name = document.getElementById('ndi_name').value;
      await fetch('/api/start', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({host, stream, ndi_name})
      });
    }

    async function stopStream() {
      await fetch('/api/stop', {method: 'POST'});
    }

    setInterval(update, 1000);
    update();
  </script>
</body>
</html>
"""

class BridgeHTTPHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/':
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.end_headers()
            self.wfile.write(HTML_PAGE.encode('utf-8'))
        elif self.path == '/api/state':
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(state).encode('utf-8'))
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        global active_engine
        content_length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_length)
        
        if self.path == '/api/start':
            data = json.loads(body.decode('utf-8'))
            state["host"] = data.get("host", "75.119.149.43")
            state["stream"] = data.get("stream", "field1")
            state["ndi_name"] = data.get("ndi_name", "Field 1 (StationCast)")
            save_config()

            if active_engine:
                active_engine.stop()

            whep_url = f"http://{state['host']}:3333/app/{state['stream']}?direction=whep"
            active_engine = OmeNdiBridgeEngine(whep_url, state["ndi_name"])
            active_engine.start()

            self.send_response(200)
            self.end_headers()
        elif self.path == '/api/stop':
            if active_engine:
                active_engine.stop()
                active_engine = None
            state["status"] = "Disconnected"
            state["status_color"] = "red"
            self.send_response(200)
            self.end_headers()

    def log_message(self, format, *args):
        pass

def main():
    global PORT, active_engine
    server = None
    for p in range(7890, 7900):
        try:
            HTTPServer.allow_reuse_address = True
            server = HTTPServer(('127.0.0.1', p), BridgeHTTPHandler)
            PORT = p
            break
        except OSError:
            continue

    if not server:
        logger.error("Could not bind HTTP server port.")
        sys.exit(1)

    url = f"http://localhost:{PORT}"
    logger.info(f"StationCast NDI Bridge Server running at {url}")
    
    try:
        webbrowser.open(url)
    except Exception:
        pass

    # Auto-start NDI engine on launch
    active_engine = OmeNdiBridgeEngine(f"http://{state['host']}:3333/app/{state['stream']}?direction=whep", state["ndi_name"])
    active_engine.start()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logger.info("Stopping NDI Bridge...")

if __name__ == "__main__":
    main()
