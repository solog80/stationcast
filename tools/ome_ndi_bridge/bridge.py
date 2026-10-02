#!/usr/bin/env python3
"""
OvenMediaEngine WebRTC (WHEP) to NDI Bridge.
Receives live WebRTC audio and video from OME and outputs a clean NDI stream
for vMix, OBS Studio (obs-ndi), and NDI receivers on macOS and Windows.
"""

import argparse
import asyncio
import logging
import sys
import numpy as np
import NDIlib as ndi
from aiortc import RTCPeerConnection, RTCSessionDescription
import aiohttp

logging.basicConfig(level=logging.INFO, format="[%(asctime)s] %(levelname)s: %(message)s")
logger = logging.getLogger("ome_ndi_bridge")

class OmeNdiBridge:
    def __init__(self, ome_url: str, ndi_name: str):
        self.ome_url = ome_url
        self.ndi_name = ndi_name
        self.pc = RTCPeerConnection()
        self.ndi_send = None

    def init_ndi(self):
        if not ndi.initialize():
            logger.error("Failed to initialize NDI SDK")
            sys.exit(1)
        send_settings = ndi.SendCreate()
        send_settings.ndi_name = str(self.ndi_name)
        send_settings.clock_video = True
        send_settings.clock_audio = True
        logger.info(f"Creating NDI send instance with name: {repr(self.ndi_name)}")
        self.ndi_send = ndi.send_create(send_settings)
        if self.ndi_send is None:
            logger.error("Failed to create NDI send instance")
            sys.exit(1)
        logger.info(f"NDI Stream initialized as '{self.ndi_name}'")

    async def run(self):
        self.init_ndi()

        @self.pc.on("track")
        def on_track(track):
            logger.info(f"Received WebRTC Track: kind={track.kind}")
            if track.kind == "video":
                asyncio.create_task(self.handle_video_track(track))
            elif track.kind == "audio":
                asyncio.create_task(self.handle_audio_track(track))

        # Add transceivers to receive video and audio
        self.pc.addTransceiver("video", direction="recvonly")
        self.pc.addTransceiver("audio", direction="recvonly")

        # Create SDP Offer
        offer = await self.pc.createOffer()
        await self.pc.setLocalDescription(offer)

        # Send SDP offer to OME WHEP endpoint
        logger.info(f"Connecting to OME WHEP endpoint: {self.ome_url}")
        async with aiohttp.ClientSession() as session:
            async with session.post(
                self.ome_url,
                data=self.pc.localDescription.sdp,
                headers={"Content-Type": "application/sdp"}
            ) as resp:
                if resp.status not in (200, 201):
                    text = await resp.text()
                    logger.error(f"OME WHEP request failed (HTTP {resp.status}): {text}")
                    return

                answer_sdp = await resp.text()
                answer = RTCSessionDescription(sdp=answer_sdp, type="answer")
                await self.pc.setRemoteDescription(answer)
                logger.info("WebRTC WHEP Handshake complete! Receiving video/audio stream...")

        # Keep running until cancelled
        try:
            while True:
                await asyncio.sleep(1)
        except asyncio.CancelledError:
            pass
        finally:
            await self.close()

    async def handle_video_track(self, track):
        video_frame = ndi.VideoFrameV2()
        while True:
            try:
                frame = await track.recv()
                img = frame.to_ndarray(format="bgr0")
                video_frame.xres = img.shape[1]
                video_frame.yres = img.shape[0]
                video_frame.FourCC = ndi.FOURCC_VIDEO_TYPE_BGRX
                video_frame.data = img
                video_frame.line_stride_in_bytes = img.strides[0]

                ndi.send_send_video_v2(self.ndi_send, video_frame)
            except Exception as e:
                logger.warning(f"Video frame decode error: {e}")
                break

    async def handle_audio_track(self, track):
        audio_frame = ndi.AudioFrameV2()
        while True:
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
            except Exception as e:
                logger.warning(f"Audio frame decode error: {e}")
                break

    async def close(self):
        if self.ndi_send:
            ndi.send_destroy(self.ndi_send)
        ndi.destroy()
        await self.pc.close()
        logger.info("NDI Bridge closed.")

def main():
    parser = argparse.ArgumentParser(description="OvenMediaEngine WebRTC to NDI Bridge")
    parser.add_argument("--url", default="http://75.119.149.43:3333/app/field1?direction=whep", help="OME WHEP URL")
    parser.add_argument("--name", default="Field 1 (StationCast)", help="NDI Stream Name")
    args = parser.parse_args()

    bridge = OmeNdiBridge(args.url, args.name)
    try:
        asyncio.run(bridge.run())
    except KeyboardInterrupt:
        logger.info("Stopping NDI Bridge...")

if __name__ == "__main__":
    main()
