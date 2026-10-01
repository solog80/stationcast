#!/usr/bin/env python3
"""
StationCast OME to NDI Bridge - Desktop GUI App
1-click standalone desktop application for Windows & macOS that receives
OvenMediaEngine WebRTC streams and publishes them as local NDI sources.
"""

import json
import logging
import os
import sys
import threading
import asyncio
import tkinter as tk
from tkinter import ttk, messagebox

import numpy as np
import aiohttp
from aiortc import RTCPeerConnection, RTCSessionDescription
import NDIlib as ndi

APP_TITLE = "StationCast OME to NDI Bridge"
CONFIG_FILE = "ndi_bridge_config.json"

class OmeNdiBridgeEngine:
    def __init__(self, whep_url, ndi_name, log_callback, status_callback):
        self.whep_url = whep_url
        self.ndi_name = ndi_name
        self.log_callback = log_callback
        self.status_callback = status_callback
        self.running = False
        self.pc = None
        self.ndi_send = None

    def log(self, msg):
        if self.log_callback:
            self.log_callback(msg)

    def set_status(self, state, text):
        if self.status_callback:
            self.status_callback(state, text)

    def start(self):
        self.running = True
        threading.Thread(target=self._run_loop, daemon=True).start()

    def stop(self):
        self.running = False

    def _run_loop(self):
        asyncio.run(self._async_run())

    async def _async_run(self):
        self.set_status("yellow", "Initializing NDI...")
        if not ndi.initialize():
            self.log("ERROR: Failed to initialize NDI SDK.")
            self.set_status("red", "NDI Init Failed")
            return

        send_settings = ndi.SendCreate()
        send_settings.ndi_name = self.ndi_name
        self.ndi_send = ndi.send_create(send_settings)
        if self.ndi_send is None:
            self.log("ERROR: Failed to create NDI send instance.")
            self.set_status("red", "NDI Create Failed")
            return

        self.log(f"NDI Stream published as '{self.ndi_name}'")
        self.pc = RTCPeerConnection()

        @self.pc.on("track")
        def on_track(track):
            self.log(f"Receiving WebRTC Track: {track.kind}")
            if track.kind == "video":
                asyncio.create_task(self._handle_video(track))
            elif track.kind == "audio":
                asyncio.create_task(self._handle_audio(track))

        self.pc.addTransceiver("video", direction="recvonly")
        self.pc.addTransceiver("audio", direction="recvonly")

        try:
            self.set_status("yellow", "Connecting to OME...")
            offer = await self.pc.createOffer()
            await self.pc.setLocalDescription(offer)

            self.log(f"Sending WHEP Offer to: {self.whep_url}")
            async with aiohttp.ClientSession() as session:
                async with session.post(
                    self.whep_url,
                    data=self.pc.localDescription.sdp,
                    headers={"Content-Type": "application/sdp"},
                    timeout=10
                ) as resp:
                    if resp.status not in (200, 201):
                        err_text = await resp.text()
                        self.log(f"ERROR: Server HTTP {resp.status}: {err_text}")
                        self.set_status("red", f"HTTP {resp.status} Error")
                        return

                    answer_sdp = await resp.text()
                    answer = RTCSessionDescription(sdp=answer_sdp, type="answer")
                    await self.pc.setRemoteDescription(answer)
                    self.log("CONNECTED! WebRTC Handshake Successful.")
                    self.set_status("green", "Streaming NDI Live")

            while self.running:
                await asyncio.sleep(0.5)

        except Exception as e:
            self.log(f"ERROR: Connection error: {e}")
            self.set_status("red", "Connection Error")
        finally:
            await self._cleanup()

    async def _handle_video(self, track):
        video_frame = ndi.VideoFrameV2()
        while self.running:
            try:
                frame = await track.recv()
                img = frame.to_ndarray(format="bgr0")
                video_frame.xres = img.shape[1]
                video_frame.yres = img.shape[0]
                video_frame.FourCC = ndi.FOURCC_VIDEO_TYPE_BGRX
                video_frame.data = img
                video_frame.line_stride_in_bytes = img.strides[0]
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
        if self.pc:
            await self.pc.close()
        if self.ndi_send:
            ndi.send_destroy(self.ndi_send)
        ndi.destroy()
        self.set_status("red", "Disconnected")
        self.log("NDI Bridge stopped.")


class BridgeAppUI(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title(APP_TITLE)
        self.geometry("520x440")
        self.resizable(False, False)
        self.configure(bg="#1E1E2E")
        self.engine = None

        self._init_styles()
        self._create_widgets()
        self._load_config()

    def _init_styles(self):
        style = ttk.Style(self)
        style.theme_use("clam")
        style.configure(".", background="#1E1E2E", foreground="#FFFFFF", font=("Segoe UI", 10))
        style.configure("TLabel", background="#1E1E2E", foreground="#D9E0EE")
        style.configure("TEntry", fieldbackground="#302D41", foreground="#FFFFFF", borderwidth=0)
        style.configure("TButton", background="#89B4FA", foreground="#1E1E2E", font=("Segoe UI", 10, "bold"), borderwidth=0)
        style.map("TButton", background=[("active", "#B4BEFE")])

    def _create_widgets(self):
        # Header
        header = tk.Frame(self, bg="#181825", height=60)
        header.pack(fill="x")
        title_lbl = tk.Label(header, text="StationCast OME to NDI Bridge", font=("Segoe UI", 14, "bold"), bg="#181825", fg="#89B4FA")
        title_lbl.pack(side="left", padx=15, pady=15)

        self.status_led = tk.Canvas(header, width=16, height=16, bg="#181825", highlightthickness=0)
        self.status_led.pack(side="right", padx=(0, 15))
        self.status_circle = self.status_led.create_oval(2, 2, 14, 14, fill="#F38BA8")

        self.status_text = tk.Label(header, text="Disconnected", font=("Segoe UI", 9), bg="#181825", fg="#CDD6F4")
        self.status_text.pack(side="right", padx=5)

        # Form Frame
        form = tk.Frame(self, bg="#1E1E2E", padx=20, pady=15)
        form.pack(fill="x")

        # Server Host
        tk.Label(form, text="Server Host / IP:", bg="#1E1E2E", fg="#CDD6F4").grid(row=0, column=0, sticky="w", pady=5)
        self.host_ent = ttk.Entry(form, width=32)
        self.host_ent.insert(0, "75.119.149.43")
        self.host_ent.grid(row=0, column=1, sticky="e", pady=5)

        # Stream Name
        tk.Label(form, text="Stream Name:", bg="#1E1E2E", fg="#CDD6F4").grid(row=1, column=0, sticky="w", pady=5)
        self.stream_ent = ttk.Entry(form, width=32)
        self.stream_ent.insert(0, "field1")
        self.stream_ent.grid(row=1, column=1, sticky="e", pady=5)

        # NDI Source Name
        tk.Label(form, text="NDI Source Name:", bg="#1E1E2E", fg="#CDD6F4").grid(row=2, column=0, sticky="w", pady=5)
        self.ndi_ent = ttk.Entry(form, width=32)
        self.ndi_ent.insert(0, "Field 1 (StationCast)")
        self.ndi_ent.grid(row=2, column=1, sticky="e", pady=5)

        # Controls
        ctrl = tk.Frame(self, bg="#1E1E2E", padx=20)
        ctrl.pack(fill="x", pady=5)

        self.start_btn = tk.Button(
            ctrl, text="▶ START NDI STREAM", font=("Segoe UI", 11, "bold"),
            bg="#A6E3A1", fg="#11111B", activebackground="#94E2D5",
            relief="flat", cursor="hand2", command=self.on_start
        )
        self.start_btn.pack(side="left", fill="x", expand=True, padx=(0, 5))

        self.stop_btn = tk.Button(
            ctrl, text="⏹ STOP", font=("Segoe UI", 11, "bold"),
            bg="#F38BA8", fg="#11111B", activebackground="#EBA0AC",
            relief="flat", cursor="hand2", state="disabled", command=self.on_stop
        )
        self.stop_btn.pack(side="right", width=100)

        # Log Text Box
        log_frame = tk.Frame(self, bg="#181825", padx=10, pady=10)
        log_frame.pack(fill="both", expand=True, padx=20, pady=(10, 15))

        self.log_txt = tk.Text(log_frame, bg="#181825", fg="#CDD6F4", font=("Consolas", 9), relief="flat", wrap="word")
        self.log_txt.pack(fill="both", expand=True)

    def log(self, message):
        def _append():
            self.log_txt.insert(tk.END, message + "\n")
            self.log_txt.see(tk.END)
        self.after(0, _append)

    def update_status(self, color_name, text):
        colors = {"green": "#A6E3A1", "yellow": "#F9E2AF", "red": "#F38BA8"}
        color = colors.get(color_name, "#F38BA8")
        def _update():
            self.status_led.itemconfig(self.status_circle, fill=color)
            self.status_text.config(text=text)
        self.after(0, _update)

    def on_start(self):
        host = self.host_ent.get().strip()
        stream = self.stream_ent.get().strip()
        ndi_name = self.ndi_ent.get().strip()

        if not host or not stream or not ndi_name:
            messagebox.showerror("Error", "All fields are required!")
            return

        url = f"http://{host}:3333/app/{stream}?direction=whep"
        self._save_config()

        self.start_btn.config(state="disabled")
        self.stop_btn.config(state="normal")
        self.host_ent.config(state="disabled")
        self.stream_ent.config(state="disabled")
        self.ndi_ent.config(state="disabled")

        self.engine = OmeNdiBridgeEngine(url, ndi_name, self.log, self.update_status)
        self.engine.start()

    def on_stop(self):
        if self.engine:
            self.engine.stop()
            self.engine = None

        self.start_btn.config(state="normal")
        self.stop_btn.config(state="disabled")
        self.host_ent.config(state="normal")
        self.stream_ent.config(state="normal")
        self.ndi_ent.config(state="normal")
        self.update_status("red", "Disconnected")

    def _save_config(self):
        config = {
            "host": self.host_ent.get().strip(),
            "stream": self.stream_ent.get().strip(),
            "ndi_name": self.ndi_ent.get().strip()
        }
        try:
            with open(CONFIG_FILE, "w") as f:
                json.dump(config, f)
        except Exception:
            pass

    def _load_config(self):
        if os.path.exists(CONFIG_FILE):
            try:
                with open(CONFIG_FILE, "r") as f:
                    config = json.load(f)
                if "host" in config:
                    self.host_ent.delete(0, tk.END)
                    self.host_ent.insert(0, config["host"])
                if "stream" in config:
                    self.stream_ent.delete(0, tk.END)
                    self.stream_ent.insert(0, config["stream"])
                if "ndi_name" in config:
                    self.ndi_ent.delete(0, tk.END)
                    self.ndi_ent.insert(0, config["ndi_name"])
            except Exception:
                pass


if __name__ == "__main__":
    app = BridgeAppUI()
    app.mainloop()
