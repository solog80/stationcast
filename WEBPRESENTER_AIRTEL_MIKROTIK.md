# Web Presenter → Airtel (MikroTik) — Work Log

Date: 2026-10-07
Host: `salt-mikrotik` — RouterOS **7.24.2** (stable), board **RB3011UiAS**

> TL;DR: The field's SRT ingest kept dropping because its route flapped between
> Savana and Simba (main table failover). The presenter was moved to the
> `airtel-first` policy list, and a **presenter-only pinned Airtel routing table
> (`bm-presenter`)** was added so its ingest no longer re-paths. Note the field
> cable was then moved to a **Savana router directly** by the operator — verify
> topology before trusting the result.

---

## 1. Inventory

| Role | Address | Notes |
|---|---|---|
| Web Presenter (field) | `192.168.1.168` | `bmd_name=Solofx Web Presenter HD`, `bmd_uuid=fc3b3a62-60ca-4904-810f-1e0a3709d1c7`, comment `BlackmagicPresenter` |
| MikroTik | `192.168.1.1` (LAN) / `10.147.17.143` (ZeroTier) | user `admin`, key `~/.ssh/id_rsa_mikrotik` |
| origin-contabo | `158.220.126.145` | OME; SRT ingest **provider :9999**, SRT **publisher :9998** (tv1) |
| origin2-salt2 | `75.119.149.43` | OME; SRT ingest provider :9999, SRT publisher :9997 (tv2) |
| Edge | `198.204.224.170` | pulls origins over OVT |

SSH pattern used:
```
ssh -o ConnectTimeout=15 -i ~/.ssh/id_rsa_mikrotik admin@192.168.1.1 '<routeros command(s)>'
```

Presenter SRT publish target (from Blackmagic custom platform `SALT-HD-STREAM`):
```
srt://158.220.126.145:9999?latency=4000
streamid: srt=158.220.126.145/tv1/stream
(backup) srt://75.119.149.43:9999  streamid srt=75.119.149.43/app/stream
```

---

## 2. Network model on the MikroTik

**LAN:** `192.168.1.0/24` on `bridge` (the presenter lives here).

**WANs (all via `check-gateway=ping` probe routes in `main`):**

| WAN | iface | iface IP | probe GW | immediate-gw |
|---|---|---|---|---|
| Savana | ether1 | 192.168.1.3/24 | 1.1.1.1 | 192.168.1.1%ether1 |
| Simba  | ether2 | 192.168.102.43/24 | 8.8.8.8 | 192.168.102.1%ether2 |
| MTN    | ether3 | 10.10.100.221/24 | 4.2.2.2 | (inactive) |
| Airtel | ether4 | 192.168.3.195/24 | 9.9.9.9 | 192.168.3.1%ether4 |
| UTL    | ether5 | 192.168.2.100/24 | 1.0.0.1 | 192.168.2.1%ether5 |

**Policy routing (mangle `prerouting` on `bridge`):** per-source address-lists
(`mtn-first`, `airtel-first`, `utl-first`, `simba-first`; default = savana) mark a
*connection*, then mark *routing* into tables `mtn-pref / airtel-pref / utl-pref / simba-pref`.

**Critical gotcha:** every routing-mark rule is gated by
`dst-address-list=!no-simba`. The `no-simba` list contains the LAN, ZeroTier
subnets, **and the two origins**:
```
no-simba  158.220.126.145   ;;; Streaming Ingest 2
no-simba   75.119.149.43    ;;; Streaming Ingest 1
```
So **ingest traffic to the origins skips per-device policy and uses `main`**
(default Savana d1 → Simba d2 → Airtel d4). This is why changing the presenter's
`*-first` list does **not** move its ingest.

---

## 3. Problem

SRT ingest dropped/reconnected every ~1–3 min (5–8 s outage). The origin
(`origin-contabo` `SrtProvider :9999`) showed the same presenter alternating
public IPs:

```
21:29:34 disc (102.203.209.121) → 21:29:40 conn (102.204.163.59)
21:30:33 disc (102.204.163.59)  → 21:30:40 conn (102.203.209.121)
21:33:04 disc (102.203.209.121) → 21:33:09 conn (102.204.163.59)   ...
```

**Root cause:** `main` default = Savana d1 with `check-gateway=ping`; when the
Savana probe fails it fails over to Simba d2 → the path/source IP changes
mid-stream → the SRT session closes. Savana recovers → flips back → drops again.
The 5–8 s gaps also exceed the encoder's SRT buffer (`latency=4000` = 4 s), so
each one is a hard disconnect.

---

## 4. Changes made (chronological)

### 4.1 (experiment — REVERTED) `main` + `simba-pref` /32 pins
Added `/32` pins for both origins via Simba with no `check-gateway`; discovered
the `no-simba` gate made the `simba-pref` ones inert. **All removed** — router is
back to its original routes. (Net: no lingering effect.)

### 4.2 Move presenter list entry → `airtel-first` (KEPT)
Operator's standard method (address-list set + flush connections):
```
/ip firewall address-list set [find comment~"BlackmagicPresenter" or comment~"WebPresenter" or address="192.168.1.168"] \
    list=airtel-first comment="BlackmagicPresenter"
/ip firewall connection remove [find src-address~"192.168.1.168" or dst-address~"192.168.1.168"]
```
Result: presenter is now `airtel-conn` → its **general** traffic uses `airtel-pref`
(Airtel). **Ingest was unchanged** (still `main`/Savana↔Simba) because of `no-simba`.

### 4.3 Presenter-only pinned Airtel table (KEPT)
```
/routing table add name=bm-presenter fib

/ip route add dst-address=158.220.126.145/32 routing-table=bm-presenter gateway=9.9.9.9 distance=1 scope=30 target-scope=11 comment="BlackmagicPresenter ingest via Airtel - no failover"
/ip route add dst-address=75.119.149.43/32   routing-table=bm-presenter gateway=9.9.9.9 distance=1 scope=30 target-scope=11 comment="BlackmagicPresenter ingest via Airtel - no failover"

/routing rule add src-address=192.168.1.168 dst-address=158.220.126.145 action=lookup table=bm-presenter comment="BlackmagicPresenter ingest via Airtel"
/routing rule add src-address=192.168.1.168 dst-address=75.119.149.43   action=lookup table=bm-presenter comment="BlackmagicPresenter ingest via Airtel"
```
Notes:
- The table **must** be created with `fib` (otherwise `/routing rule` rejects it:
  `input does not match any value of table`).
- No `check-gateway` on the routes = **no failover** (ingest stays on Airtel; if
  Airtel truly dies it black-holes instead of flip-flopping).
- Scope: **only** `src=192.168.1.168` to those two IPs. Nothing else is affected.

### 4.4 Flushed presenter ingest conntrack (applied)
```
/ip firewall connection remove [find src-address~"192.168.1.168" and dst-address~"158.220.126.145"]
/ip firewall connection remove [find src-address~"192.168.1.168" and dst-address~"75.119.149.43"]
```

### 4.5 ⚠️ Method correction — `/routing rule` was NOT honored here; use mangle
On this RouterOS (7.24.2 / RB3011) the presenter-source `/routing rule`
(`action=lookup table=…`) entries were **silently not honored** — flows kept
egressing Savana/Simba. This router's own policy routing uses **mangle
`mark-routing`**, which **does** work. Working pattern:
```
/ip firewall address-list add list=ingest-origin address=158.220.126.145 comment="origin-contabo"
/ip firewall address-list add list=ingest-origin address=75.119.149.43   comment="origin2"
/ip firewall mangle add chain=prerouting action=mark-routing new-routing-mark=<TABLE> \
    passthrough=no src-address=<DEVICE> dst-address-list=ingest-origin in-interface=bridge \
    comment="<DEVICE> ingest via Airtel"
```
…where `<TABLE>` is a `fib` routing table holding the pinned no-`check-gateway` routes.
The dead `/routing rule` entries were removed.

### 4.6 tv2 (Salt-TV-2-Mac, `192.168.1.39`) — added 2026-10-07
tv2 source = a Mac (`38:C9:86:1E:94:2A`, list `savana-first`, comment
"Salt-TV-2-Mac"), publishing SRT → `75.119.149.43:9999` (`#default#tv2/live`),
flapping `.121 ↔ .59` like tv1. Applied the **mangle** variant (list left as-is):
```
/routing table add name=tv2-presenter fib
/ip route add dst-address=158.220.126.145/32 routing-table=tv2-presenter gateway=9.9.9.9 distance=1 scope=30 target-scope=11 comment="tv2 ingest via Airtel - no failover"
/ip route add dst-address=75.119.149.43/32   routing-table=tv2-presenter gateway=9.9.9.9 distance=1 scope=30 target-scope=11 comment="tv2 ingest via Airtel - no failover"
/ip firewall mangle add chain=prerouting action=mark-routing new-routing-mark=tv2-presenter passthrough=no src-address=192.168.1.39 dst-address-list=ingest-origin in-interface=bridge comment="tv2 ingest via Airtel"
```
Verified: `.39` ingest flow egresses **`192.168.3.195` (Airtel)**, steady ~2.4 Mbps.

### 4.7 tv1 (Web Presenter `192.168.1.168`) — pre-pinned to **Simba** (2026-10-07)
The presenter's cable was moved to a Savana router, so tv1 does not currently
traverse this MikroTik. To be ready when the cable is moved back, the
`bm-presenter` table was repointed **Airtel → Simba** and the (working) mangle
rule added:
```
/ip route set [find where routing-table="bm-presenter"] gateway=8.8.8.8 comment="BlackmagicPresenter ingest via Simba - no failover"
/ip firewall mangle add chain=prerouting action=mark-routing new-routing-mark=bm-presenter \
    passthrough=no src-address=192.168.1.168 dst-address-list=ingest-origin in-interface=bridge \
    comment="tv1 ingest via Simba"
```
Result: `bm-presenter` `/32` routes → immediate-gw `192.168.102.1%ether2` (**Simba**),
no `check-gateway`. Takes effect only when `.168` traffic passes this router again.

> Current ingest mangle rules (both above the generic `*-pref` rules):
> 0 = `src=192.168.1.39` → `tv2-presenter` (Airtel), 1 = `src=192.168.1.168` → `bm-presenter` (Simba).

---

## 5. Verify

**On the MikroTik** — presenter's ingest should now SNAT to Airtel (`192.168.3.195`)
and stay there (no Savana/Simba flip):
```
/ip firewall connection print detail where src-address~"192.168.1.168"
# look for: dst-address=158.220.126.145 dst-port=9999  → reply-dst-address=192.168.3.195
```
```
/routing rule print
/ip route print detail where routing-table=bm-presenter
```

**On origin-contabo** — field connects should stop alternating IPs and the
disconnect cadence should drop:
```
ssh origin-contabo 'docker logs -t --since 15m ome-primary-backup | grep SPSRT-s9999'
```

---

## 6. Rollback

**tv2 pin (mangle + table):**
```
/ip firewall mangle remove [find where comment~"tv2 ingest via Airtel"]
/ip route remove [find where routing-table="tv2-presenter"]
/routing table remove [find where name="tv2-presenter"]
```

**tv1 / `bm-presenter` (orphaned — routing rules already removed):**
```
/ip route remove [find where routing-table="bm-presenter"]
/routing table remove [find where name="bm-presenter"]
```

**Revert the `airtel-first` list move (tv1), if desired:**
```
/ip firewall address-list set [find comment~"BlackmagicPresenter"] list=simba-first comment="BlackmagicPresenter"
/ip firewall connection remove [find src-address~"192.168.1.168" or dst-address~"192.168.1.168"]
```

---

## 7. Open items / follow-ups

- [x] **tv2** pinned to Airtel via mangle + `tv2-presenter` table — verified stable.
- [x] **tv1** pre-pinned to **Simba** (mangle + `bm-presenter` table) for when the
      cable is moved back to this MikroTik. Not currently traversing it (cable on
      a Savana router), so no live flow to verify yet.
- [ ] **Failover semantics:** `tv2-presenter` / `bm-presenter` are Airtel-only
      (no fallback). If Airtel is unreliable, consider a dedicated fallback table.
- [ ] Consider raising the encoder SRT `latency` (`4000` → ~`8000`) to absorb
      short transport gaps (adds field-side delay).
- [ ] Optional: stop the origin2 restreamer reconnect **storm** on
      `origin-contabo:9998` (add reconnect backoff to restreamer ingest
      `081a1eda`) so a field blip doesn't cascade downstream.
- [ ] Optional: measure each WAN properly (ICMP is rate-limited/unreliable here);
      use a sustained UDP/SRT probe to pick the least-bad uplink.

---

## 8. Quick reference — useful queries

```
# presenter flows + egress SNAT
/ip firewall connection print detail where src-address~"192.168.1.168"

# presenter list membership
/ip firewall address-list print detail where address="192.168.1.168"

# routing tables / rules
/routing table print
/routing rule print

# WAN default routes (main)
/ip route print detail where routing-table=main and dst-address="0.0.0.0/0"
```

---

## 9. origin2-salt2 (`75.119.149.43`) OME app cleanup — 2026-10-09

Removed the legacy inline `app` application so this origin has **only `tv1` and `tv2`**.
`tv1` here is the **backup** receiver for the Web Presenter (primary tv1 lives on
the other VPS); `tv2` is the existing second channel.

Config: `/root/OME_DOCKER_HOME/origin_conf/` (host-networked container
`ovenmediaengine`). **OME's REST API is not reachable** — port 8081 is owned by
`nimble`, so verify via config + logs, not the API.

Changes:
```
cp -n Server.xml Server.xml.bak.rmapp.$(date +%s)
cd applications && cp -n tv2.xml tv1.xml && sed -i 's#<Name>tv2</Name>#<Name>tv1</Name>#' tv1.xml
# remove the inline <Application><Name>app</Name>…</Application> block from Server.xml (python regex)
docker restart ovenmediaengine
```

Resulting `<Applications>`:
```
<Applications>
    <Application include="applications/*.xml" />   <!-- → tv1.xml, tv2.xml -->
</Applications>
```

Verify: `grep -c "<Name>app</Name>" Server.xml` → `0`; `ls applications/` → `tv1.xml tv2.xml`.
Rollback: restore `Server.xml.bak.rmapp.*`, remove `applications/tv1.xml`, restart OME.

> The Web Presenter's backup must now target **`tv1`** instead of `…/app/stream`
> (e.g. streamid `srt=75.119.149.43/tv1/<name>`); the `tv1` app is ready to receive it.

---

## 10. Edge (`198.204.224.170`) Origins cleanup — 2026-10-09

Clients were still hitting `stream.salttelevision.com/app/stream/abr.m3u8` and
`…/app/stream2/abr.m3u8`; the edge's `/app/` Origin (fast-fail `127.0.0.1:1`)
produced pull attempts + 404s. Replaced `<Origins>` so the edge serves **only tv1 and tv2**:

- `/tv1/` → `158.220.126.145:9000/tv1/` (primary) + `75.119.149.43:9000/tv1/` (failover/backup)
- `/tv2/` → `75.119.149.43:9000/tv2/`
- **removed** the `/app/` Origin and the catch-all `/`

Config: `/home/customer/OME_DOCKER_HOME/edge_conf/Server.xml` (container
`ovenmediaengine`). Backup: `Server.xml.bak.rmapp.*`. Restart: `docker restart ovenmediaengine`.

Verified (edge `:3333`):
```
/tv1/stream/llhls.m3u8 -> 200   /tv1/stream/abr.m3u8 -> 200
/tv2/live/llhls.m3u8   -> 200   /tv2/live/abr.m3u8   -> 200
/app/stream/abr.m3u8   -> 404   /app/stream2/abr.m3u8 -> 404
```
`app/*` now returns `Could not find the origin` (no pull attempt).

> Clients still *request* the old `/app/...` URLs (404) — that comes from the
> player/page; update it to tv1/tv2 to fully stop the 404s.
> `H264Parser … Could not parsed VUI parameters of SPS` warnings are harmless
> (ingest H.264 lacks VUI params).
> Thumbnails (`/tv1/stream_preview/thumb.webp`) currently 404 on BOTH edge and
> origin — unrelated to this change; needs a separate look.

---

## 11. Web Presenter switched to the **backup** (feeds 75) — 2026-10-09

Reason: origin-contabo (158) was overloaded (load ~18); moved the field encode to 75.

Blackmagic **Web Presenter** (`192.168.1.168`) via its control API
(`/control/api/v1`):
```
# 1. fix the backup streamid (was the retired .../app/stream)
PUT /livestreams/customPlatforms/SALT HD.xml     (application/xml, HTTP 204)

# 2. switch active server to the backup + restart the stream
PUT /livestreams/0/activePlatform  {"platform":"SALT-HD-STREAM","server":"Backup Stream","quality":"Mid"}  (HTTP 500, but state applied)
PUT /livestreams/0/stop    (204)
PUT /livestreams/0/start   (204)
```

`SALT HD.xml` servers (unchanged URLs, **backup streamid fixed**):
```
Backup Stream : srt://75.119.149.43:9999?latency=4000   streamid srt=75.119.149.43/tv1/stream   ← now active
Primary Stream: srt://158.220.126.145:9999?latency=4000  streamid srt=158.220.126.145/tv1/stream
```

Verified: 75 receives `bmd_name=Solofx Web Presenter HD`, `streamid srt=75.119.149.43/tv1/stream`, `tv1/stream` LLHLS ready.

**Edge follow-up:** with tv1 now sourced from 75, the edge `/tv1/` Origin was still
158-first → tv1 returned 404. Flipped the order to **75-first (158 fallback)** in
`edge_conf/Server.xml` (backup `Server.xml.bak.tv1swap.*`) and restarted the edge OME.
Result: `/tv1/... -> 200`, `/tv2/... -> 200`.

> Caveat: uploading the platform XML reset the quality profile to its `High` default
> (was `Mid`). Set it via `activePlatform` if you want `Mid` back.

---

## 12. Load rebalance — tv1→75, tv2→158 — 2026-10-09

Cause of the "slow to load": **origin `75` was saturated** (`us 88%`, load ~17) because
it was transcoding **both** tv1 and tv2 ladders at once. (158 was idle after tv1 left it.)

Actions:
- **75**: disabled the `tv2` app — `applications/tv2.xml` → `tv2.xml.disabled`, restart
  `ovenmediaengine`. Now **tv1 only**; load dropped ~17 → ~11. *(Apps are enabled/disabled
  purely by matching the `applications/*.xml` include — rename out to disable, back to enable.)*
- **158**: deactivated everything except `tv2`. Renamed `00_template.xml`, `app1.xml`,
  `app.xml`, `ome.xml`, `tv1.xml` → `*.xml.disabled` (kept on disk), and created
  `applications/tv2.xml` (copy of `tv1.xml`, name changed). Dir backup:
  `ome_origin_conf/applications.bak.*.tgz`. Restart `ome-primary-backup`.
  Result: only the `tv2` app; load ~1.7.
- **Edge** (`edge_conf/Server.xml`, backup `Server.xml.bak.tv2to158.*`):
  - `/tv1/` → **75 only** (dropped the dead 158 fallback)
  - `/tv2/` → **158 primary + 75 fallback**
  Restarted. `/tv1/... -> 200`; `/tv2/... -> 404` **until the tv2 ingest is repointed to 158**
  (158's tv2 has no source yet, 75's tv2 is disabled).

Operator task: repoint the **tv2 ingest** (Salt-TV-2-Mac `192.168.1.39`) to **158**
(`srt://158.220.126.145:9999`, streamid `…/tv2/live`). tv2 then comes up on 158.
