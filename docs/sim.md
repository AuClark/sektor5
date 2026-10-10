# Synthetic rig (working without the hardware)

`brain/sim/run.sh` runs the whole app on your computer against a **synthetic rig**, so you can work on it with the decks, mixer, lights and brain switched off.

```bash
brain/sim/run.sh               # an endless auto-mixed set at 126 BPM
brain/sim/run.sh --bpm 132     # faster
brain/sim/run.sh --no-auto     # nothing mixes itself; load and play from the dashboard
```

It opens the Decks page. The other pages are at the usual ports on `localhost`:

| Page | Address |
|---|---|
| Decks | http://localhost:8080 |
| Lighting (Commander) | http://localhost:8090 |
| Projection | http://localhost:8100/edit |
| Stage | http://localhost:8100/stage.html |
| Visuals | http://localhost:8110 |

Press Ctrl-C to stop everything. Each service's log is in `brain/sim/logs/`. Edits to the pages show when you refresh; edits to the Python services need a restart.

## What's real and what's synthetic

- **Real:** showbrain, the projector service and the visuals service. They're the actual code from the repo, unchanged, doing exactly what they do on the brain.
- **Synthetic:** `brain/sim/fakerig.py` stands in for deckdash (the Java service that talks to the XDJs) and the DJM mixer bridge.
  - It speaks the same protocols: the dashboard API on :8080, and showbrain's UDP feed on :9100 (deck status 20×/s, a packet per beat, and mixer messages).
  - It plays an endless DJ set of 40 generated tracks. Each track has a real phrase structure: intro, grooves, breakdowns, 8–16 bar builds, drops, outro.
  - For each track it provides what the real deckdash would: a timeline with drops, sections, energy and a beat grid; overview and detailed waveforms; and library entries. Playlists are Warm up, Peak time and Trance.
  - **Auto-mix:** the next track starts on the outgoing track's outro, synced to its tempo. Its fader comes up over 8 bars, then the bass and tempo master swap. The old track fades out over 8 bars, and the next track is loaded behind it.
  - **Mixer:** channel levels, share, bass-out (in breakdowns and on the bass swap) and kicks all follow what's playing.
  - **Melody:** each track has a generated lead line in its key (two 2-bar motifs: sparse in the intro, a riff in the groove, long notes in breakdowns, a rising arpeggio in builds, an octave up in drops), reported as the mixer's melody analysis would be (note, chroma, onsets), so the laser show has a melody to follow.
  - **Dashboard controls:** load, play (it starts on the other deck's next beat), stop, SYNC, MASTER and seek all work. With `--no-auto`, you run the set yourself.
- **Not simulated:**
  - Light output: showbrain sends to 127.0.0.1, so nothing lights up. Use the Commander's fixture preview or the Stage view instead.
  - The admin PIN: it's off locally, so everyone is admin.
  - Tempo-master control, album art, set recording and the System view's Pi stats.

## Requirements

- Python 3 with `numpy`. On macOS with Homebrew Python, a global `pip install` is refused (PEP 668), so `run.sh` makes a virtualenv at `brain/sim/.venv` and installs numpy there the first time it needs to. It only does this if `numpy` is genuinely missing, so a machine that already has it is untouched.
- Ports 8080, 8090, 8100 and 8110 must be free. The script checks and names any that are taken.

**About `s5auth.js`:** on the brain, `deploy.sh` copies it next to each service. Locally, `run.sh` links it into place instead. The links are git-ignored.

## On a Mac with the real rig

`./run.sh`, at the root of the repo, launches the same app on a Mac against the **real** rig instead of the synthetic one: deckdash on the decks over Pro DJ Link, the leg pyramids and rave tubes over the router's Wi-Fi, and the par can on a uDMX in the Mac. No Pi needed. `./run.sh stop` stops it; logs go to `logs/`.

- **Network:** plug the rig router and the decks into the Mac's Ethernet. The router has no internet but offers itself as the gateway, so first run `sudo brain/tools/mac_rig_ethernet.sh` (a fixed address, no gateway: the internet stays on Wi-Fi), and once `sudo brain/tools/mac_rig_ethernet.sh permanent` (Wi-Fi first in the service order). Addresses come from `.env`: `S5_ROUTER_IP`, `S5_MAC_RIG_IP`. It also gives that Ethernet a self-assigned 169.254.x.x address (a second network service on the same port, which macOS keeps): decks switched on before the router is ready give themselves 169.254 addresses, still see each other, and without it the Mac can't hear them at all. `undo` removes both.
- **Needs:** Homebrew `openjdk@21` (it builds deckdash from the checkout when the sources change), numpy, and for the par can `pyusb` with Homebrew `libusb`.
- **Fixtures** by their `.local` names, or `S5_PYRAMID_L_HOST` etc. in `.env`. No panel unless `S5_RIG_BOX_HOST` is set.
- **Decks:** it starts on the real decks and waits with **NO DECKS** if there are none; the simulation is offered there, and switches itself off when real decks turn up.

### Deck connection tests

Run these on the rig after changing deckdash, the run script or the network, with `python3 brain/tools/djlink_watch.py` open in a terminal: it prints a line whenever the connection, the decks, the deck the lights follow or the par can's USB DMX change, and how long the connection took to come back. Pass when the watcher shows `joined` with both decks, and the lights follow a playing deck, within the time given. No step may need a restart of the show.

| # | Do | Pass |
|---|---|---|
| 1 | Cold start: router on for a minute, decks on, Mac plugged in, then `./run.sh` | `joined`, both decks, within 15 s |
| 2 | With a track playing, unplug the Mac's Ethernet for 10 s, plug it back | `lost the DJ Link network: rejoining` then `joined` in `deckdash.log`; back within 15 s; the lights follow the same deck and track |
| 3 | Unplug the whole USB-C hub for 10 s, plug it back | As 2, and the par can's DMX `connected` again |
| 4 | Unplug one deck's Ethernet for 10 s, plug it back | The other deck keeps driving the show; the unplugged one comes back by itself |
| 5 | Start the show with the Mac's Ethernet unplugged, then plug it in | It waits (`NO DECKS`); joins by itself within 15 s of plugging in |
| 6 | Restart the router with the decks on | The show waits, then joins the decks on the router's addresses. A deck that asks for an address before the router's DHCP is up takes a self-assigned 169.254 one and keeps it (seen 2026-10-10); the show then joins the router's side anyway, the beat still works, and the Live pill says to replug that deck |

**Keeping the decks on the router's addresses.** XDJs have no static IP setting, and after a failed DHCP request they keep a self-assigned address until their Ethernet is replugged. A router restart drops their link, and they ask again before its DHCP is up. So: put a small unmanaged switch between the router and the decks + Mac (the decks' links stay up through a router restart, so they keep their addresses); reserve each deck's address in the router's DHCP settings; and on a cold start, power the router about a minute before the decks.
| 7 | Leave the Mac idle (lid open) for 15 min with the show running | Still `joined`; the run script keeps the Mac awake (`caffeinate`) |
| 8 | With decks connected, try **Start simulation** (`POST /api/sim {"on":true}`); then unplug both decks | Refused while decks are there; **NO DECKS** offers it once they're gone |

## On the brain

The brain can run the same synthetic rig, so a Pi on the bench (or at home, with no decks) shows the whole app working, and the real lights follow the generated set.

- **When no decks are found**, every page shows a **NO DECKS** pill at the top right, next to the lock. Tap it for **Start simulation** (needs admin, the PIN) or **Not now**.
- **While it runs**, an amber **SIM** pill replaces the page's LIVE pill (it's the simulator, not the decks). Tap it for sound, volume and **Back to real decks**. Everything else is real: showbrain, the lights, projection, visuals, the Stage view, the admin PIN and the System view.
- **Nothing sticks:** stopping it, restarting deckdash or rebooting goes back to the real decks.
- **Never over real decks:** with any deck (or DJ Link mixer) on the network, deckdash refuses to start the simulation, and the **LIVE** pill no longer offers it. If one turns up while it runs, the simulation switches itself off within about 2 s.
- API: `GET /api/sim`, `POST /api/sim {"on": true|false, "bpm": 126}` (admin). Also in `/api/system` as `sim`.

How it works: deckdash ([`Sim.java`](../brain/deckdash/Sim.java)) runs `fakerig.py` (copied to `~/sim/` by `brain/deploy.sh deckdash`) on port 8079, passes the deck data API through to it (`/api/state`, `/api/events`, timelines, waveforms, library, `/api/deck`, `/api/tempo`), and stops sending its own deck feed to showbrain while fakerig sends the synthetic one. The mixer service is paused meanwhile, because with no DJM it would keep telling showbrain the mixer is unplugged. Its log is `/tmp/fakerig.log`.

### Sound

Tap the **speaker** (left of the SIM pill in the top bar) for sound in that browser, in time with the show. The sound lives in a small player page (`/shell`, [`s5shell.html`](../brain/common/web/s5shell.html)) that shows the control pages inside itself, so it keeps playing while you switch between Decks, Lighting, Projection, Visuals and Stage. Tapping the speaker on a normal page moves you into the player (it looks the same; the address bar shows `/shell#…`); going back to the real decks leaves it. Browsers need one tap before they'll make sound: until then the speaker pulses. The **SIM** pill's panel has the volume.

- **Real tracks** (below) play their actual audio, one player per deck, following the deck's position, pitch, fader and bass EQ as the sim mixes (the bass swap is a real low cut). It stays within a few tens of milliseconds of the deck, at the deck's exact pitch. When the page is busy (a heavy sketch or a transition on the same machine) it holds its course instead of jumping to catch up: a late position reading is ignored, and it only jumps when the smoothed drift is over 200 ms or the deck really moved (a seek, a new track).
- **Synthetic tracks** have no audio, so [`s5audio.js`](../brain/common/web/s5audio.js) synthesises house music that follows showbrain's beat clock: kick, hats, clap and bassline in grooves and drops; a pad and a dark filter in breakdowns; a filter sweep, snare roll and riser in builds; a beat of silence before the drop.

### Your own tracks

The sim on the brain can play real tracks: put them in `/srv/rave/sim/tracks/` (never in git: they're the DJ's music). They come first in the library (**My tracks**), and the auto set plays only them when there are any. One folder per track:

```
/srv/rave/sim/tracks/01-artist-title/
  track.mp3                          the audio
  track.json                         {"title", "artist", "genre", "bpm", "key", "duration"}
  ANLZ0000.DAT  ANLZ0000.EXT  ANLZ0000.2EX   the track's rekordbox analysis, from the USB's PIONEER/USBANLZ/…
```

[`realtracks.py`](../brain/sim/realtracks.py) reads the analysis: the beat grid (so the decks run on the track's real grid, first downbeat included), rekordbox's phrases (intro / up / down / chorus / outro become intro / build / breakdown / drop / outro) and the colour waveform for the dashboard. Keys become Camelot. Restart the sim (or deckdash) to pick up new folders.

**Only tracks with full rekordbox analysis are used:** phrases (turn on **Phrase** in rekordbox's analysis settings), a key, and at least one drop in the phrases. Anything else is skipped (the reason is in `/tmp/fakerig.log`): the sim is for testing the show against tracks whose structure is known, so nothing is guessed. The current set (2026-09-29) is six tech house tracks from the DJ's USB, 123–127 BPM.
