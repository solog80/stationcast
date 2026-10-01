#!/usr/bin/env python3
"""
Build script to package StationCast OME to NDI Bridge into a 1-click standalone executable.
Generates:
  - Windows: dist/StationCast_NDI_Bridge.exe
  - macOS: dist/StationCast_NDI_Bridge.app (or standalone binary)
"""

import os
import sys
import subprocess

def build():
    print("Building StationCast OME to NDI Bridge Executable...")
    try:
        import PyInstaller
    except ImportError:
        print("Installing PyInstaller...")
        subprocess.check_call([sys.executable, "-m", "pip", "install", "pyinstaller"])

    cmd = [
        sys.executable, "-m", "PyInstaller",
        "--noconfirm",
        "--onedir",
        "--windowed",
        "--name", "StationCast_NDI_Bridge",
        "--hidden-import", "NDIlib",
        "--hidden-import", "aiortc",
        "--hidden-import", "aiohttp",
        "--hidden-import", "av",
        "--hidden-import", "numpy",
        "web_bridge.py"
    ]

    print("Running command:", " ".join(cmd))
    subprocess.check_call(cmd)
    print("\n✅ Build Successful!")
    print("Executable generated in: dist/StationCast_NDI_Bridge/")

if __name__ == "__main__":
    build()
