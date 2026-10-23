#!/usr/bin/env python3
"""Minimal AMI helper for the dev presenter conference.

Usage:
  python3 ami_presenters.py list
  python3 ami_presenters.py mute   <channel>
  python3 ami_presenters.py unmute <channel>

Reads the AMI secret from /opt/asterisk-dev/ami.secret. This is a development
tool; the production control plane will live in the BFF.
"""

import argparse
import pathlib
import socket
import sys

HOST = "100.82.159.75"
PORT = 5039
USER = "stationcast-dev"
SECRET_PATH = pathlib.Path("/opt/asterisk-dev/ami.secret")
CONFERENCE = "presenters"


class Ami:
    def __init__(self) -> None:
        self.sock = socket.create_connection((HOST, PORT), 5)
        self.sock.settimeout(5)

    def send(self, action: str) -> None:
        self.sock.sendall(action.encode())

    def read_until(self, marker: str) -> str:
        buf = b""
        while marker.encode() not in buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                break
            buf += chunk
        return buf.decode(errors="replace")

    def read_response(self) -> str:
        """Read one AMI action response, discarding interleaved events."""
        buf = b""
        while True:
            chunk = self.sock.recv(4096)
            if not chunk:
                break
            buf += chunk
            if b"Response:" in buf:
                tail = buf.split(b"Response:", 1)[1]
                if b"\r\n\r\n" in tail:
                    break
        text = buf.decode(errors="replace")
        idx = text.rfind("Response:")
        return text[idx:] if idx >= 0 else text

    def login(self) -> None:
        secret = SECRET_PATH.read_text().strip()
        self.send(
            f"Action: Login\r\nUsername: {USER}\r\nSecret: {secret}\r\n\r\n"
        )
        if "Response: Success" not in self.read_response():
            raise SystemExit("AMI login failed")

    def logout(self) -> None:
        try:
            self.send("Action: Logoff\r\n\r\n")
        finally:
            self.sock.close()

    def list(self) -> list[dict[str, str]]:
        self.send(f"Action: ConfbridgeList\r\nConference: {CONFERENCE}\r\n\r\n")
        out = self.read_until("ConfbridgeListComplete")
        members: list[dict[str, str]] = []
        current: dict[str, str] = {}
        for line in out.splitlines():
            if line.startswith("Event: ConfbridgeList"):
                if current:
                    members.append(current)
                current = {}
            elif ":" in line and line.split(":", 1)[0] in {
                "Channel",
                "CallerIDNum",
                "CallerIDName",
                "Muted",
                "Admin",
            }:
                key, value = line.split(":", 1)
                current[key] = value.strip()
        if current:
            members.append(current)
        return members

    def mute(self, channel: str, mute: bool) -> None:
        action = "ConfbridgeMute" if mute else "ConfbridgeUnmute"
        self.send(
            f"Action: {action}\r\nConference: {CONFERENCE}\r\n"
            f"Channel: {channel}\r\n\r\n"
        )
        response = self.read_response()
        if "Response: Success" not in response:
            raise SystemExit(f"{action} failed: {response.strip()}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("command", choices=["list", "mute", "unmute"])
    ap.add_argument("channel", nargs="?")
    args = ap.parse_args()

    ami = Ami()
    try:
        ami.login()
        if args.command == "list":
            members = ami.list()
            if not members:
                print("no participants")
            for m in members:
                print(
                    f"{m.get('Channel', '?'):45} "
                    f"{m.get('CallerIDName', '')} <{m.get('CallerIDNum', '')}> "
                    f"muted={m.get('Muted', '?')}"
                )
        else:
            if not args.channel:
                raise SystemExit("channel required")
            ami.mute(args.channel, mute=args.command == "mute")
            print(f"{args.command} ok: {args.channel}")
    finally:
        ami.logout()


if __name__ == "__main__":
    main()
