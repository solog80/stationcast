# StationCast Radio (SIP/EBU 3326) — Working Setup Reference

Status: **VERIFIED WORKING** — two-way contribution audio between the field phone
(StationCast) and the studio Comrex ACCESS Rack through an Asterisk relay.

## Topology

```
field phone (StationCast, SIP UA)
   │  registers as "field"  (UDP 5060, digest auth)
   ▼
Asterisk 22.10.1 on Edge2 (142.54.173.186)   <-- RTP relay, direct_media=no
   ▲  registers as "station"
   │
studio Comrex ACCESS Rack (wired into mixer, auto-answers)
```

Both ends live behind symmetric NAT and only dial **out**, so no inbound port
forwarding is required anywhere. Asterisk learns each peer's real NAT source
from registration and relays media between them.

## Server: Edge2 (142.54.173.186)

Asterisk 22.10.1 in Docker (`andrius/asterisk:latest`), auto-restart.

```
docker run -d --name asterisk --restart unless-stopped \
  -p 5060:5060/udp \
  -p 31000-31100:31000-31100/udp \
  -v /opt/asterisk/etc:/etc/asterisk \
  -v /opt/asterisk/sounds:/var/lib/asterisk/sounds \
  andrius/asterisk:latest
```

Configs in `/opt/asterisk/etc/`: `pjsip.conf`, `extensions.conf`, `rtp.conf`.

### pjsip.conf — THE critical fix
The transport MUST advertise the server's public IP for media, or Asterisk
advertises its Docker-internal IP (172.17.x) and no RTP can reach it:

```
[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0:5060
external_signaling_address=142.54.173.186
external_media_address=142.54.173.186
external_signaling_port=5060
```

Endpoints: `station` (Comrex) and `field` (phone). Both:
- `direct_media=no`  (media hairpins through Asterisk)
- `rtp_symmetric=yes`, `force_rport=yes`, `rewrite_contact=no`
- allow g722, opus, ulaw, alaw
- digest auth per endpoint

### rtp.conf
```
[general]
rtpstart=31000
rtpend=31100
externip=142.54.173.186
; localnet MUST NOT include 172.16/12 (docker bridge) or peers are treated
; as local and the SDP address is never rewritten to externip.
localnet=127.0.0.0/8
localnet=10.0.0.0/8
localnet=192.168.0.0/16
rtcpinterval=2000
strictrtp=no
```

### extensions.conf
```
exten => 100,1,Dial(PJSIP/station,45)   ; field -> studio
exten => 200,1,Dial(PJSIP/field,45)     ; studio -> field
exten => user,1,Dial(PJSIP/field,45)    ; legacy comrex direct-dial
```

## Accounts

| Peer | User | Password | AOR | Notes |
|---|---|---|---|---|
| Comrex (studio) | `station` | CHANGEME_station_2026 | station | registers to 142.54.173.186 |
| Field phone | `field` | CHANGEME_field_2026 | field | registers, calls ext `100` |

## App (StationCast radio page)

- Radio line: registrar `142.54.173.186`, user `field`, pass `CHANGEME_field_2026`,
  extension `field`, codec G.722.
- "Call Studio" dials `sip:100@<registrar>` (the Comrex).
- The Comrex profile shows "TX: X3 VoIP G.722" when connected — G.722 is what
  actually negotiates and carries audio.

## Comrex side

- SIP/EBU 3326 connection set to **Register** to `142.54.173.186:5060`
  as `station` / `CHANGEME_station_2026`.
- Accept incoming connections = yes (auto-answers so the field can dial in).

## Troubleshooting notes

- Symptom "connects then drops ~32s / no audio": almost always RTP not reaching
  the server because the SDP advertised the Docker-internal IP. Fix =
  `external_media_address` on the transport.
- SIP scanner flood: whitelist 5060/RTP to the two known peer IPs in Docker's
  `DOCKER-USER` iptables chain (not INPUT — Docker DNAT bypasses it).
- The Field Tap app (linphone) was used as a working reference — it registered
  identically and proved the server config before our engine matched it.

## Licenses

- Asterisk: GPLv2. PJSIP (app engine): GPLv2 or commercial.
- Confirm licensing before any store release.
