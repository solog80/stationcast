# Asterisk Development Environment (Edge2)

Live radio must stay up while we build SIP multiuser. All experiments run in a
**separate container** on separate ports. The live `asterisk` container is not
touched unless we explicitly promote a tested config.

## Live vs dev

| | Live | Dev |
|---|---|---|
| Container | `asterisk` | `asterisk-dev` |
| SIP UDP | `5060` | `5062` |
| RTP UDP | `31000-31100` | `31200-31300` |
| AMI | disabled | `127.0.0.1:5039` (host only) |
| Config dir | `/opt/asterisk/etc` | `/opt/asterisk-dev/etc` |
| Sounds | `/opt/asterisk/sounds` | same, mounted read-only |
| Restart policy | unless-stopped | unless-stopped |

Both run `andrius/asterisk:latest` (Asterisk 22.10.1) and advertise the same
public IP `142.54.173.186`. The dev transport is bound to `5062` and its RTP
range is `31200-31300`, so it cannot collide with live media.

## Backup (taken before creating dev)

Location: `/opt/asterisk-backups/` (mode 700, files mode 600)

```
asterisk-etc-2026-10-22-105633.tgz      # /opt/asterisk/etc
asterisk-container-2026-10-22-105633.json
dialplan-2026-10-22-105633.txt
endpoints-2026-10-22-105633.txt
```

Restore (only during a maintenance window):

```
sudo docker stop asterisk
sudo rm -rf /opt/asterisk/etc
sudo tar -xzf /opt/asterisk-backups/asterisk-etc-2026-10-22-105633.tgz -C /opt/asterisk
sudo docker start asterisk
```

## Dev credentials

- Dev `station` and `field` endpoint secrets were **rotated**, so production
  SIP credentials cannot register against the dev SIP port.
- Stored on the server: `/opt/asterisk-dev/presenters.env` (mode 600).
  Add lines with `asterisk-dev/add_presenters.py`; the full generator rotates
  every existing presenter password.
- AMI: user `stationcast-dev`, secret in `/opt/asterisk-dev/ami.secret`
  (mode 600). AMI is published only on `127.0.0.1:5039`.
- Access AMI over an SSH tunnel:

```
ssh -L 5039:127.0.0.1:5039 Edge2
# then connect AMI to localhost:5039
```

## Working with dev

```
# status / logs
ssh Edge2 "docker ps --filter name=asterisk-dev; docker logs --tail 50 asterisk-dev"

# reload after editing configs
ssh Edge2 "docker exec asterisk-dev asterisk -rx 'pjsip reload'"
ssh Edge2 "docker exec asterisk-dev asterisk -rx 'dialplan reload'"
ssh Edge2 "docker exec asterisk-dev asterisk -rx 'module reload app_confbridge'"

# inspect
ssh Edge2 "docker exec asterisk-dev asterisk -rx 'pjsip show endpoints'"
ssh Edge2 "docker exec asterisk-dev asterisk -rx 'confbridge list'"
```

Test clients register to `142.54.173.186:5062`. The live apps/Comrex continue
to use `5060` and are unaffected.

## Promoting to live (after testing)

1. Take a fresh backup of live: repeat the `tar`/`docker inspect` commands with
   a new timestamp.
2. Diff configs, then copy only the intended files:
   ```
   sudo cp /opt/asterisk-dev/etc/pjsip.conf      /opt/asterisk/etc/pjsip.conf
   sudo cp /opt/asterisk-dev/etc/extensions.conf /opt/asterisk/etc/extensions.conf
   sudo cp /opt/asterisk-dev/etc/confbridge.conf /opt/asterisk/etc/confbridge.conf
   sudo cp /opt/asterisk-dev/etc/manager.conf    /opt/asterisk/etc/manager.conf
   ```
3. Reload live (`pjsip reload`, `dialplan reload`, `module reload app_confbridge`),
   or restart during a maintenance window.
4. Verify a real Comrex + app radio call, then tear down or keep dev as a lab.

## Security notes

- `5062/udp` is currently reachable from the internet (like live `5060`).
  Restrict it with firewall rules during testing if no remote softphones need it.
- Dev uses separate secrets; do not copy `/opt/asterisk-dev/presenters.env` into git.
- AMI is read/write `all` for the dev user. It is bound to localhost and only
  intended for the control service via a tunnel/private network.

## Teardown

```
ssh Edge2 "docker rm -f asterisk-dev"
```

The backup remains in `/opt/asterisk-backups/`.
