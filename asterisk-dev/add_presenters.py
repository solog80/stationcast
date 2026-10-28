#!/usr/bin/env python3
"""Append missing SIP presenter lines without rotating existing passwords.

Usage on Edge2:
  sudo python3 /opt/asterisk-dev/add_presenters.py --upto 10

Existing presenter sections and credentials are left untouched. New lines are
appended with fresh random passwords and written to presenters.env (mode 600).
"""

import argparse
import pathlib
import re
import secrets


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--start", type=int, default=5)
    ap.add_argument("--upto", type=int, default=10)
    ap.add_argument("--number-base", type=int, default=2000)
    ap.add_argument("--context", default="presenters")
    ap.add_argument(
        "--config",
        default="/opt/asterisk-dev/etc/pjsip-presenters.conf",
    )
    ap.add_argument(
        "--creds",
        default="/opt/asterisk-dev/presenters.env",
    )
    args = ap.parse_args()

    config = pathlib.Path(args.config)
    creds = pathlib.Path(args.creds)
    conf_text = config.read_text()
    creds_text = creds.read_text()

    existing_sections = set(re.findall(r"^\[(presenter\d+)\]", conf_text, re.M))
    existing_creds = set(re.findall(r"^(presenter\d+)=", creds_text, re.M))

    blocks: list[str] = []
    new_creds: list[str] = []
    added: list[tuple[str, int]] = []

    for i in range(args.start, args.upto + 1):
        name = f"presenter{i}"
        if name in existing_sections or name in existing_creds:
            print(f"skip {name}: already exists")
            continue

        number = args.number_base + i
        label = f"Presenter {i}"
        password = secrets.token_hex(16)

        blocks.append(
            f"""[{name}]
type=endpoint
context={args.context}
disallow=all
allow=opus
allow=g722
allow=ulaw
allow=alaw
direct_media=no
rtp_symmetric=yes
force_rport=yes
rewrite_contact=no
rtp_timeout=30
auth={name}-auth
aors={name}
callerid="{label}" <{number}>

[{name}-auth]
type=auth
auth_type=userpass
username={name}
password={password}

[{name}]
type=aor
max_contacts=3
remove_existing=yes
qualify_frequency=30
"""
        )
        new_creds.append(
            f"{name}={password} | number={number} | context={args.context}"
        )
        added.append((name, number))

    if not blocks:
        print("No new presenter lines needed.")
        return

    config.write_text(conf_text.rstrip("\n") + "\n\n" + "\n".join(blocks) + "\n")
    creds.write_text(creds_text.rstrip("\n") + "\n" + "\n".join(new_creds) + "\n")
    config.chmod(0o640)
    creds.chmod(0o600)

    print("Added:")
    for name, number in added:
        print(f"  {name} / {number}")
    print("Passwords stored in", creds, "(not printed)")


if __name__ == "__main__":
    main()
