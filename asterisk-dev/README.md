# Asterisk dev: presenter conference

Config fragments for the `asterisk-dev` container on Edge2. Live Asterisk
(`5060`) is not touched. See `../ASTERISK_DEV.md` for the container/backup
details.

## Files

- `confbridge-presenters.conf` — `presenters_bridge` / `presenters_user` profiles.
- `extensions-presenters.conf` — `[presenters]` context: room `7000`, legacy dial `100` (app), test dial `7100`.
- `generate_pjsip_presenters.py` — writes presenter endpoints + credentials.
- `ami_presenters.py` — dev helper: list / mute / unmute participants via AMI.

## Apply to dev

```
scp asterisk-dev/* Edge2:/tmp/asterisk-dev-files/
ssh Edge2 'sudo bash -s' <<'EOF'
install -m 640 /tmp/asterisk-dev-files/confbridge-presenters.conf /opt/asterisk-dev/etc/
install -m 640 /tmp/asterisk-dev-files/extensions-presenters.conf /opt/asterisk-dev/etc/
install -m 750 /tmp/asterisk-dev-files/generate_pjsip_presenters.py /opt/asterisk-dev/
python3 /opt/asterisk-dev/generate_pjsip_presenters.py --count 3

for f in pjsip.conf extensions.conf confbridge.conf; do
  inc="#include ${f%.conf}-presenters.conf"
  grep -qxF "$inc" /opt/asterisk-dev/etc/$f || echo "$inc" >> /opt/asterisk-dev/etc/$f
done

docker exec asterisk-dev asterisk -rx "pjsip reload"
docker exec asterisk-dev asterisk -rx "dialplan reload"
docker exec asterisk-dev asterisk -rx "module reload app_confbridge.so"
EOF
```

`pjsip.conf` gets `#include pjsip-presenters.conf`; `extensions.conf` gets
`#include extensions-presenters.conf`; `confbridge.conf` gets
`#include confbridge-presenters.conf`.

Credentials: `/opt/asterisk-dev/presenters.env` (mode 600). Passwords are never
printed by the generator.

### Permissions gotcha

Asterisk runs as uid `1000` (`asterisk`) inside the container. Included files
owned by `root` with mode 640 are unreadable and produce
`#include ... does not exist (Permission denied)`. After installing:

```
chown 1000:1000 /opt/asterisk-dev/etc/pjsip-presenters.conf                  /opt/asterisk-dev/etc/extensions-presenters.conf                  /opt/asterisk-dev/etc/confbridge-presenters.conf
chmod 640 /opt/asterisk-dev/etc/*presenters.conf
```

Also restart the dev container after adding new includes; `pjsip reload` does
not recover objects after an initial parse failure:

```
ssh Edge2 "docker restart asterisk-dev"
```

## Test

Register a softphone (Linphone/Zoiper) to `142.54.173.186:5062` as
`presenter1` (password from `presenters.env`), then dial `7000`.

Two presenters should each hear the other and the Comrex return, but not
themselves. With no Comrex in the room yet, you will only hear the other
presenter(s).

Room check from the CLI:

```
docker exec asterisk-dev asterisk -rx "confbridge list presenters"
docker exec asterisk-dev asterisk -rx "dialplan show presenters"
```

Temporary local participant (30s):

```
docker exec asterisk-dev asterisk -rx "channel originate Local/7000@presenters application Wait 30"
docker exec asterisk-dev asterisk -rx "confbridge list presenters"
```

## Producer UI path

The dashboard (`/broadcast/radio`, Live Radio) does not talk to AMI directly. It calls the
Next API, which verifies the admin session and forwards to the Dart BFF with a
shared `RADIO_CONTROL_KEY`. The BFF reaches AMI over the tailnet.

- AMI publish: `100.82.159.75:5039` on Edge2 (dev only; not public)
- BFF env: `ASTERISK_AMI_HOST=100.82.159.75`, `ASTERISK_AMI_PORT=5039`,
  `ASTERISK_AMI_USER`, `ASTERISK_AMI_SECRET`, `ASTERISK_CONFERENCE=presenters`,
  `RADIO_CONTROL_KEY`
- Next env (`.env.local`): `RADIO_BFF_URL=https://edge.solofx.net`,
  `RADIO_CONTROL_KEY`
- Endpoints: `GET /api/v1/bff/radio/participants` (admin `x-radio-key`),
  `POST /api/v1/bff/radio/mute`, `POST /api/v1/bff/radio/comrex`,
  and `GET /api/v1/bff/radio/presenters` (mobile Firebase ID token) for the
  app's swipe-up presenter directory.
- **Presenters join muted** (`presenters_user: startmuted=yes`); the Comrex
  uses `comrex_user` (`startmuted=no`), selected by
  `ASTERISK_CONFERENCE_USER=comrex_user` in the BFF env.
- Comrex endpoint: `PJSIP/station` originated with
  `Application: ConfBridge` and
  `Data: presenters,presenters_bridge,presenters_user`; disconnect hangs up
  the station channel.

## Verified on dev (2026-10-22)

- `presenter1..3` endpoints loaded (`2001..2003`).
- Dialplan `7000` and `7100` loaded.
- `ConfBridge(presenters,presenters_bridge,presenters_user)` accepts joins.
- AMI `ConfbridgeList` shows participants; `ConfbridgeMute` / `ConfbridgeUnmute`
  return Success and change the `Muted` flag.

```
# list current participants / mute one
sudo python3 /opt/asterisk-dev/ami_presenters.py list
sudo python3 /opt/asterisk-dev/ami_presenters.py mute "<channel>"
sudo python3 /opt/asterisk-dev/ami_presenters.py unmute "<channel>"
```

## Comrex leg

`7100` dials `PJSIP/station` for a one-to-one test. To place Comrex *inside*
the conference, use AMI `Originate` with `Application: ConfBridge` and
`Data: presenters,presenters_bridge,presenters_user` once Comrex is pointed at
the dev port (maintenance window).

## Promote

Only after the dev tests pass: back up live, copy the tested files to
`/opt/asterisk/etc`, add the same `#include` lines, fix ownership (live files
are `customer:customer 644`), then reload live during a maintenance window.
See `../ASTERISK_DEV.md`.
