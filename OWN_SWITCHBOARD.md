# Own SIP Switchboard — Bypassing Comrex for a Multi-Unit Contribution Fleet

**Status:** Design / proposal — Phase 0 (Edge2 PoC) not yet started.
**Date:** 2026-09-03
**Owner:** Solomon (Salt)

---

## 1. Goal

Replace the single Comrex ACCESS Rack + Comrex Switchboard/CrossLock cloud dependency with **our own SIP hub** built on the Edge2 Asterisk relay, so we can run a **fleet of field audio/video broadcast units** (phones running StationCast, later hardware) into the studio — the same way our SRT fleet works, but for real-time EBU 3326/contribution audio with proper broadcast mix-minus.

**Why:** the Comrex is one unit, can't do multiple units at once, has opaque return-feed routing (the source of the ongoing "return audio not heard" problem), and its Switchboard/CrossLock path is CGNAT-hostile. Our own Asterisk hub removes all of that.

## 2. The core idea

Every unit **registers out** to Edge2 Asterisk (a public VPS), exactly like the field phone already does. Because endpoints dial out to a public host, **CGNAT is irrelevant** — no inbound ports, no CrossLock, no Comrex cloud. Asterisk becomes the "switchboard."

**The return-feed problem dies by construction:** the studio program simply comes back **down the SIP call**, mix-minus per participant, computed by Asterisk. No proprietary routing to fight.

```
field-01 (app) ──┐
field-02 (app) ──┤  register out (CGNAT-safe)   ┌──────────────────────┐
field-03 (app) ──┼─────────────────────────────►│ Edge2 Asterisk hub    │──► studio PC softphone
   ...           │                               │  per-show bridge      │◄── (USB audio to console)
studio PC ───────┘                               │  true mix-minus graph │
(USB to console)                                 └──────────────────────┘
```

## 3. Decisions (confirmed)

| Decision | Choice |
|---|---|
| Concurrency | **N field units → one studio** |
| Mixing model | **True mix-minus hub** (remotes never hear other remotes — only studio program) |
| Studio termination | **PC + USB audio interface to the console** |
| Go-live trigger | **Server dials out via Asterisk ARI** (admin app triggers the hub) |
| Fleet control | **Live push from the admin app** to each unit |

> ⚠️ Revisit: if callers hearing each other during a *panel* is acceptable, a plain ConfBridge is dramatically simpler and Phase 0 changes. "True mix-minus" is the hard path.

## 3b. Field finding — CrossLock actually NEEDS inbound UDP 9000/9001 (not purely outbound)

**Empirically confirmed (2026-09-04):** CrossLock between the outdoor Comrex and the studio does **not** establish on a purely-outbound basis in practice. The Comrex relay (`sb-balancer.comrex.com` = 13.59.93.103, UDP 3478/9001 + TCP 8090) only completes the CrossLock tunnel when it can reach the unit's **inbound UDP 9000 + 9001**.

Observed behaviour across the outdoor unit's site hops:
- **Studio LAN** (192.168.10.x) — works: no NAT at all.
- **Simba site router** (192.168.100.1) — works after **DMZ** enabled; that router already had **UDP 9000 + 9001 port-forwards**, which is the inbound path CrossLock needs.
- **Airtel site router** (192.168.102.1) — **fails** ("CrossLock to studio won't establish") with no DMZ/forward. Reaching Comrex's relay *outbound* was fine from Airtel, but the inbound path to the unit was closed → tunnel can't establish.

**Implication:** each remote site running a Comrex unit behind NAT needs **DMZ → unit** **or** explicit inbound **UDP 9000 + 9001** (the relay returns on ~3478 too). This corrects the earlier "no port opening needed for CrossLock" assumption and matters for any site that can't offer that inbound path (e.g. true CGNAT) — for those, CrossLock will not work and Switchboard-only fallback may also fail.

Secondary issues that also affect this unit's CrossLock over cellular (old firmware, see changelog v5.5-p1): MTU < 1500 handling and STUN stuck at "UDP Blocked" under CGNAT. Config can't fully patch those; they need the 5.x firmware.

## 4. Architecture

### 4.1 Edge2 Asterisk = the hub
- N field endpoints (`field-01 … field-NN`) + one `studio-op` endpoint (the PC softphone).
- Per-show bridge application with a **true mix-minus graph** (not plain ConfBridge):
  - **Uplink:** all connected `R_i` sum into one **"REMOTES" feed** → studio PC → console fader (board hears/airs all callers as one source).
  - **Return:** console's mix-minus aux (host + music + air, REMOTES fader excluded) returns over USB → Asterisk → delivered to **every** remote. Since the return already excludes the remotes bus, no caller hears self or any other caller.
- ARI enabled for origination/mute/kick (config exists on Edge2; no user defined yet). AMI currently disabled.
- Existing state (Edge2): pjsip transport w/ external media address, `rewrite_contact=yes`, endpoints `station/100` (Comrex) + `field/200`, ConfBridge module loaded, current dialplan is 1:1 only (`extensions.conf`).

### 4.2 Studio side (replaces Comrex XLR/AES)
- PC running a softphone registered as `studio-op` on Edge2.
- USB audio interface = the codec to the console (console line input for REMOTES, console mix-minus/aux back to the callers).
- This is the only genuinely "new hardware-ish" piece vs. what we already run.

### 4.3 Field app (station_cast)
- PJSIP radio engine already works and registers out (`lib/radio/`, `radio_controller.dart` → `sip:100@host`).
- Change: per-unit extension + conference target; `SipPreset` points at the hub.
- Fix per-unit identity: config today is keyed `broadcastConfig/user_<uid>` (one doc per signed-in user) — a fleet needs `dev_<deviceId>` docs so one admin drives many units.
- Wire the **dead** `onConfigChanged` Firestore listener (`lib/services/broadcast_reporter.dart:44-48`) into the radio/broadcast controllers → live go-live / preset / return-feed push.

### 4.4 Admin app (saltmedia-admin-app)
- `src/app/broadcast/page.tsx` already lists units (`broadcasts/`) and edits `broadcastConfig/…`.
- Extend into the hub control panel: pick a unit → **Put on air** → new API route → **Asterisk ARI dials the unit into the show**; live per-unit status; mute/kick in the conference; push per-unit config.

## 5. Data model (control plane)

Today:
- `broadcasts/<broadcasterId>` — per-unit status beacon (heartbeat every 5s, snapshot every 10s).
- `broadcastConfig/user_<uid>` — per-unit remote config (read once at provider init; live listener exists but is unwired).

Needed for a fleet:
- `broadcastConfig/dev_<deviceId>` (unit-keyed, not user-keyed) so one logged-in admin can drive every unit.
- A per-unit **command channel** (Firestore doc or ARI) the admin app writes / Asterisk executes.

Relevant code today:
- `station_cast/lib/services/broadcast_reporter.dart` — status + dead config listener.
- `station_cast/lib/services/settings_sync.dart` — config push/pull (user-keyed).
- `station_cast/lib/broadcast/providers.dart` — merges remote config at init.
- `station_cast/lib/models/sip_preset.dart`, `lib/radio/*` — SIP line config + call.
- `saltmedia-admin-app/src/app/broadcast/page.tsx` — monitor + config editor.

## 6. Phased implementation

### Phase 0 — Edge2 PoC (de-risk the mixer graph first, no app changes)
- 2 test remotes + 1 program channel.
- Prove: uplink sum → "REMOTES" feed; each remote receives **only** program return (no self, no other remote).
- Decide/confirm the "true mix-minus" vs "panel ConfBridge" question with real audio.
- **This is the riskiest unknown — do not touch apps until proven.**

### Phase 1 — Asterisk multi-unit hub
- Add `field-01…NN` + `studio-op` pjsip endpoints.
- Per-show bridge app (dialplan) implementing the mix-minus graph.
- ARI origination: server dials a unit out and joins it to the show.
- Admin mute/kick per participant.

### Phase 2 — Studio PC endpoint
- Softphone registered `studio-op`, USB audio interface to the console.
- Verify levels + no echo/feedback (mix-minus correctness).

### Phase 3 — Field app identity + live push
- Switch config to `dev_<deviceId>` docs.
- Wire `onConfigChanged` → controllers (go-live / preset / return-feed / radio line).
- Retarget `callStudio` to the per-unit conference entry.

### Phase 4 — Admin hub UI + API
- New backend route(s) → Asterisk ARI.
- Extend broadcast page: Put on air / take off air, live status, mute/kick, per-unit config.

## 7. Open items / revisit list
1. **True mix-minus vs panel ConfBridge** — hard isolation is significantly more work; confirm it's required.
2. **Studio console wiring detail** — which console, how the mix-minus aux is derived, single vs multi USB channel.
3. Whether field units should also carry SRT video uplink / SRT return-feed (existing fleet) **in parallel** with the SIP audio line (likely yes — same unit, two legs).
4. Asterisk ARI security (ARI user + firewall) before exposing to the admin backend.
5. What happens to the existing Comrex/`station` endpoint (keep for legacy, or retire once the hub is proven).
6. **CrossLock inbound requirement (§3b)** — each NAT'd Comrex site needs DMZ or UDP 9000/9001 inbound to the unit; note this as a deployment constraint when the Comrex is used at remote sites (our own Asterisk/SIP hub design doesn't need this since units call out).

## 8. Related docs / files
- `RADIO_SIP_SETUP.md` — verified-working single field→Comrex setup this replaces.
- `station_cast/lib/radio/radio_controller.dart` — field dial (`sip:100@host`).
- `station_cast/lib/services/broadcast_reporter.dart` — status + unwired config listener.
- `station_cast/lib/services/settings_sync.dart`, `lib/broadcast/providers.dart` — config plane.
- `saltmedia-admin-app/src/app/broadcast/page.tsx` — current monitor/config UI.
