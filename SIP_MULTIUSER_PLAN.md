# SIP Multiuser Plan

Status: Draft for review
Scope: Multiple SIP presenters feeding one Comrex, with mix-minus monitoring and producer-controlled routing.

## Goal

Multiple presenters connect over SIP. All presenters hear the studio return but **not themselves**. The producer puts a presenter "on air" into the Comrex only when they are ready. Comrex still sees **one** connection.

## Key insight

This is primarily an **Asterisk conference/mix** problem, not a multi-account problem in the app. Each phone keeps one SIP account; Asterisk mixes the presenters and feeds Comrex.

## Current state

- Asterisk 22.10.1 on Edge2 (`142.54.173.186`), Docker (`andrius/asterisk:latest`).
- Comrex ACCESS Rack registers as `station`; the app registers as `field`.
- Dialplan: `100 -> Dial(PJSIP/station)` (field to studio), `200 -> Dial(PJSIP/field)`, `user -> Dial(PJSIP/field)`.
- App: one `SipPreset`, one PJSIP account, one call slot; outbound is hardcoded to `sip:100@<host>`.
- Mesh `broadcast_config.radio` holds one line per Firebase UID; admin lock supported.
- `app_confbridge.so` is running; AMI/ARI modules are available.
- `direct_media=no`, symmetric RTP, and public `external_media_address` already configured.
- RTP range: `31000-31100` (~50 calls at 2 ports each).

## Development environment (ready)

Live Asterisk stays untouched. All multiuser work happens in a separate
container on Edge2:

| | Live | Dev |
|---|---|---|
| Container | `asterisk` | `asterisk-dev` |
| SIP UDP | `5060` | `5062` |
| RTP UDP | `31000-31100` | `31200-31300` |
| AMI | disabled | `127.0.0.1:5039` (host only) |
| Config | `/opt/asterisk/etc` | `/opt/asterisk-dev/etc` |

- Live config backup: `/opt/asterisk-backups/asterisk-etc-2026-10-22-105633.tgz`
  (plus container inspect, dialplan, endpoints).
- Dev endpoint secrets are rotated; stored in `/opt/asterisk-dev/creds.env`.
- AMI user `stationcast-dev`; secret in `/opt/asterisk-dev/ami.secret`.
- Full runbook: `ASTERISK_DEV.md`.
- ConfBridge room `7000` is configured and verified in dev:
  - endpoints `presenter1..3` (`2001..2003`)
  - profiles `presenters_bridge` / `presenters_user`
  - AMI list/mute/unmute verified
  - two real phones joined room 7000; mix-minus and mute/unmute confirmed
  - producer UI implemented: `/broadcast/radio` (Live Radio) lists participants, mutes, and
    connects/disconnects the Comrex leg via BFF -> AMI (shared control key,
    admin role only)
  - AMI exposed to the BFF over the tailnet at `100.82.159.75:5039`
  - remaining: Comrex leg in the room, app conference target
- Promote dev -> live only after testing, with a fresh backup.

## Recommended topology

```
presenter1..N (SIP, unique extensions)
        |  Opus (48k), direct_media=no
        v
Asterisk 22.10.1 on Edge2 (142.54.173.186)
        |
   ConfBridge "presenters"  --->  PJSIP/station (Comrex ACCESS, auto-answer)
        ^                              |
        +---- Comrex RX = studio return-+

ConfBridge gives each presenter the mix of everyone else (no self).
Producer mutes a presenter to keep their mic off the Comrex bus until ready.
```

- **Return**: presenters hear Comrex RX plus other presenters through the conference mix.
- **Mix-minus**: native ConfBridge behavior - a participant is never sent their own audio.
- **Routing**: `ConfbridgeMute/Unmute` per channel (AMI) controls who is on the Comrex bus; muted presenters still hear the room.
- **Comrex**: Asterisk originates `PJSIP/station` into the conference when the room starts; re-originate on drop.

## Workstreams

### 1. Asterisk (Edge2 dev -> live)

- Build and test in `asterisk-dev` (`5062`, RTP `31200-31300`); see `ASTERISK_DEV.md`.
- Add presenter endpoint/AOR/auth pairs (`presenter1..N`) using templates.
- Default to **Opus** end-to-end (Comrex negotiates Opus) to avoid transcoding; G.722 is only a fallback.
- Add `exten => 7000,1,ConfBridge(presenters)` in a restricted `[presenters]` context; keep `100` as the legacy one-to-one path.
- Configure `confbridge.conf`:
  - no join/leave announcements
  - sane mixing interval
  - max members
  - music/hold behavior when alone
- Enable a restricted AMI/ARI user for the control service.
- Originate `PJSIP/station` into the conference; watchdog and re-originate on hangup.
- Expand `rtp.conf` range if more than ~50 participants; review Edge2 CPU for mixing and any transcoding.
- Keep the existing NAT settings (`external_signaling_address`, `external_media_address`, `rtp_symmetric`, `force_rport`).

### 2. Control plane + producer console (implemented in dev)

- Private link Edge <-> Edge2 (WireGuard/Tailscale preferred) for AMI. Otherwise deploy a small authenticated agent on Edge2 behind HTTPS.
- Implemented BFF endpoints:
  - `GET /api/v1/bff/radio/participants`
  - `POST /api/v1/bff/radio/mute` (`channel`, `muted`)
  - `POST /api/v1/bff/radio/comrex` (`connected`: originate/hang up
    `PJSIP/station` into the room)
  - both protected by `x-radio-key: $RADIO_CONTROL_KEY`
- Implemented dashboard page `saltmedia-admin-app/src/app/broadcast/radio` (Live Radio, under Broadcasts):
  - polls participants every 2.5 s
  - Mute / Route (Unmute) buttons
  - admin session required (Next API verifies the Firebase role claim)
  - added to the sidebar under Radio -> Studio and linked from Broadcast Monitor
- Cache AMI events and push them to the dashboard.
- New dashboard page **Live Radio** (`/broadcast/radio`, under Broadcasts):
  - participant list: name, extension, state, network
  - Ready queue
  - Route / Unmute, Mute, Remove
  - "On air" indicator and Comrex online status
- Access: admin/producer role only, scoped per station.
- Optional phase 2: producer private cue to a waiting presenter (requires per-user mix or a second path).

### 3. App changes

- Replace hardcoded `sip:100@host` with a provisioned **conference target** (e.g. `7000`); label the action "Join Studio"; keep `100` as fallback.
- The **SIP conference is the return**: each presenter hears the Comrex RX plus
  the other presenters, never themselves. SRT is not part of the radio path.
- The app's separate SRT return/talkback feature must stay **off** in radio
  mode; using it alongside SIP would add a second, delayed return.
- Add local mic mute, Ready button, and On-air / "muted by producer" indicators (BFF -> mesh realtime).
- Enable/verify PJSIP echo cancellation (WebRTC AEC, tail ~200-500 ms); essential with speakerphone.
- Report presence to the BFF: uid, name, extension, ready/on-air, muted.
- The radio page polls `GET /api/v1/bff/radio/presenters` (Firebase ID token,
  verified by the BFF via Identity Toolkit) every 3 s. A second, swipe-up
  **Connected presenters** page shows account names, Google/custom photos,
  `YOU`, and `MUTED`/`ON AIR`. It is hidden when no presenters are connected,
  so the radio page is unchanged in single-user mode.
- The app-facing directory is read-only and never hangs calls. The producer
  dashboard endpoint keeps its auto-hang duplicate behaviour.
- Keep one SIP account per phone; unique credentials per presenter continue to arrive through `broadcast_config.radio` (per uid), with admin lock.

### 4. Provisioning, identity, security

- Dashboard roster: assign extension/name/password per presenter (Firebase users), generate Asterisk endpoints, push `radio` config.
- **Fix the current credential exposure before onboarding many users**: `broadcast_config` is anon-SELECT, so anyone with the public key can read every radio/SRT password. Options:
  - issue a per-user Supabase JWT from the BFF after Firebase auth, with RLS `user_id = auth.uid()`; or
  - make config reads BFF-only and keep Realtime behind authenticated tokens.
- Server hardening: strong per-user SIP secrets, fail2ban, conference PIN if needed, optionally SIP TLS/SRTP later.
- Keep the admin lock (`radio.locks.radio`) so presenters cannot edit provisioned lines.

### 5. Test & rollout

- **Phase A**: 2-3 softphones (Linphone/Zoiper) + Comrex.
  - confirm no self-audio
  - confirm return is present
  - confirm producer mute affects Comrex only
- **Phase B**: control API + dashboard.
  - verify routing with 2+ presenters
- **Phase C**: two phones with the app.
  - echo/AEC
  - speaker vs earpiece
  - confirm the separate SRT return/talkback feature is off in radio mode
- **Phase D**: 5-10 participant load.
  - latency/jitter
  - Comrex reconnect
  - Asterisk restart
  - onboarding + runbook

## Critical prerequisites / risks

- **Studio return must be a mix-minus** (no presenter mics). If the Comrex return is the full program including remotes, presenters will hear themselves delayed regardless of ConfBridge.
- **Echo**: without AEC and/or headphones, open speaker + return causes feedback into the conference.
- **Codec**: keep Opus end-to-end; mixing codecs across presenters would make Asterisk transcode N streams.
- **Stereo is not available through Asterisk 22**: `codec_opus` exposes no stereo/channel option
  (official module config), the endpoint codec is mono, and ConfBridge mixes mono. The Comrex
  will show `Opus Mono` even if the app offers `opus/48000/2`. True stereo needs a different
  media server/mixer or a separate stereo return path.
- **Latency**: conference + jitter buffer adds delay; measure before promising a "live" feel.
- **Single point of failure**: Edge2 Asterisk; add monitoring and restart policy.
- **Producer private cue** is not possible in one shared room without extra mixing; decide if needed.
- **Licensing**: PJSIP is GPLv2 or commercial; Asterisk is GPLv2. Confirm before store release.

## Decisions needed

1. While waiting, should presenters hear the other presenters (ConfBridge default) or only the studio return?
2. One presenter on Comrex at a time, or mix several simultaneously?
3. Is the Comrex/studio return already a clean mix-minus excluding remote mics?
4. Does the producer need to talk privately to a waiting presenter ("stand by"), or is public talkback fine?
5. Who is "producer" (existing `admin` role, or a new role) and do they need station scoping?
6. Max concurrent presenters and expected codec (Opus Mono is the current default)?
7. Can Edge reach Edge2 privately for AMI, or should we deploy a small control agent on Edge2?
8. Should the app's separate SRT return/talkback feature remain available in radio mode, or be disabled so SIP is the only return path?

## Likely files to change

**Asterisk (Edge2)**
- `/opt/asterisk/etc/pjsip.conf`
- `/opt/asterisk/etc/extensions.conf`
- `/opt/asterisk/etc/confbridge.conf`
- `/opt/asterisk/etc/manager.conf` or `ari.conf`
- `/opt/asterisk/etc/rtp.conf`

**Mesh / BFF**
- `saltmedia/functions/superbase/migrations/` (radio presence/roster, RLS)
- `saltmedia/packages/saltmedia_bff/bin/server.dart` (radio control + presence endpoints)

**Dashboard**
- `saltmedia-admin-app/src/app/broadcast/` or new `src/app/radio/`
- `src/app/api/...` (control proxy, roster)

**App**
- `lib/models/sip_preset.dart` (dial target / conference room, display name)
- `lib/radio/radio_controller.dart` (join conference, mute, ready)
- `lib/radio/providers.dart` (presence, remote state)
- `lib/ui/radio_screen.dart`, `lib/ui/widgets/sip_preset_editor.dart`
- `plugins/station_broadcast/lib/src/sip_client.dart`, `sip_models.dart`
- `plugins/station_broadcast/android/.../SipEngine.kt`
- `plugins/station_broadcast/ios/.../StationSip.{h,m}`
