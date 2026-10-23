# Two-phone SIP conference test (dev)

Status: **VERIFIED 2026-10-22** — both phones joined room 7000; muting
Presenter 1 removed them from what Presenter 2 heard; unmute restored it.
Presenter 2's mute was also verified (their contribution disappeared).

Current app auth is still Firebase (mesh carries the SIP config). Asterisk dev
is on `5062`; live radio on `5060` is untouched.

## 0. Get the dev credentials

```
ssh Edge2 "sudo cat /opt/asterisk-dev/presenters.env"
```

Use `presenter1` / `presenter2` and their passwords. Extensions are
`presenter1` / `presenter2` (numbers `2001` / `2002`).

## 1. Phones in the dashboard

- Sign each phone into the app. Use **different Firebase accounts** if you
  want a different SIP line per phone; the same account shares one config.
- Open Settings once so the app registers in `broadcasts` (Firestore).
- Dashboard `/broadcast` should list the devices (currently `Solo Samsung` and
  `Abel Kitaka` if those are the two phones).

## 2. Provision the radio line

Dashboard -> select device -> **Radio Line (SIP)**:

| Field | Phone 1 | Phone 2 |
|---|---|---|
| Enabled | ON | ON |
| Name | Presenter 1 | Presenter 2 |
| Codec | Opus | Opus |
| Registrar Host | `142.54.173.186` | `142.54.173.186` |
| Port | `5062` | `5062` |
| Username | `presenter1` | `presenter2` |
| Password | from `presenters.env` | from `presenters.env` |
| Extension | `presenter1` | `presenter2` |
| Auto-answer | OFF | OFF |

Blur each field (or Tab) to save; the mesh write is instant.

## 3. Join the conference

On each phone: open **Radio** (registers the line), then press
**Call Studio**. The app dials `100`; in dev, `100` joins
`ConfBridge(presenters,...)`, so both phones land in room `7000`.

Expected: each phone joins **MUTED**. Unmute each card in **Broadcasts → Live Radio** (`/broadcast/radio`) when
ready. After unmuting, each phone hears the other, **not itself** (ConfBridge
mix-minus). Use headphones; speaker feedback sounds like self-audio.

## 4. Simulate producer routing

```
ssh Edge2 "sudo python3 /opt/asterisk-dev/ami_presenters.py list"
ssh Edge2 "sudo python3 /opt/asterisk-dev/ami_presenters.py mute '<channel>'"
ssh Edge2 "sudo python3 /opt/asterisk-dev/ami_presenters.py unmute '<channel>'"
```

Muting removes that presenter from what the other hears (the future Comrex
bus). Quote the channel because it contains `;`.

## 5. When finished

Set **Enabled OFF** on both devices (or restore the live radio server
`142.54.173.186:5060`). This stops the dev registrations.

## Troubleshooting

- **No device in dashboard:** open Settings on the phone, refresh; the app
  registers `broadcasts/<uid>` on startup.
- **Radio stays "not configured":** host, username, and extension must all be
  set; then reopen the Radio screen.
- **Registration fails/401:** re-copy the password from `presenters.env`;
  secrets were rotated for dev.
- **No audio between phones:** confirm both show registered, both pressed
  Call Studio, and the dashboard Port is `5062` (not `5060`).
- **Echo/self-audio:** use headphones first; conference mix-minus does not
  cancel acoustic feedback from a speaker.
- **Dashboard save error:** log in again via `/login` (session cookie).
