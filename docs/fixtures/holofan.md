# Hologram fan (PD42)

A 42 cm LED hologram fan ("3D Holographic Fan", model **PD42**, 1024 × 640, app **Holoscope**). It shows clips stored on its microSD card. The goal: showbrain picks and plays clips with the show. Tool: [`fixtures/holofan/holofan.py`](../../fixtures/holofan/holofan.py).

**Status (4 Oct 2026):** controlled from a Mac on the fan's Wi-Fi: it connects, stays connected, reports its status and file list, and takes brightness changes (confirmed in its status). Play / pause / clip / power use the same framing but haven't been tried live yet. Uploading new content isn't done (see [Uploads](#uploads-not-done)). Not a showbrain fixture yet.

## Setup

- **It needs a microSD card** (FAT32, 32 GB or less) in the slot on the hub. Without one the app shows "File: 0" and every upload fails with "Transfer failed code:12".
- It makes its own Wi-Fi network, `3D-PD42-1024*640-<serial>`, password `12345678`; the fan is `192.168.4.1`.
- **One controller at a time.** The app's "Other applications in the same LAN" warning means it has seen another controller's announcement (another phone, the app on a second device, or this tool).
- Android: the app only has "selected photos" access; add a picture to its selection (Settings → Apps → Holoscope → Photos and videos) before it can upload it.

## Protocol

Learned from Holoscope 2.5.2 (`javainterface.OpenAndroidAlbum`, a Qt app; the logic is in `libappHoloscope`), decompiled with Ghidra, and checked against the fan.

**Discovery is backwards:** the controller is the server.
1. The controller broadcasts its own IP followed by `HS` (e.g. `192.168.4.2HS`) on **UDP 8988** (the app: every 2.5 s, from port 8988).
2. The fan connects to the controller on **TCP 6666**. Nothing listens on the fan itself.
3. The controller sends a heartbeat, `5A 0D 0D F5 00`, every second (and `5A 1C 1C F5 00` once): without it the fan hangs up after about 6 s.

**Messages** are raw bytes, `5A <cmd> [arg] <check> F5`, where the check byte repeats the byte before it.

| To the fan | Bytes |
|---|---|
| Power on / off | `5A 01 01 F5` / `5A 02 02 F5` |
| Play / pause | `5A 04 04 F5` / `5A 03 03 F5` |
| Loop one clip / loop all | `5A 05 05 F5` / `5A 06 06 F5` |
| Brightness *n* (0–255) | `5A 81 n n F5` |
| Play clip *i* (0-based) | `5A 87 i+1 i+1 F5` |
| Volume *n* | `5A 90 n n F5` |
| Join a Wi-Fi network | 68 bytes: `5A 8B`, SSID (32 bytes, zero-padded), password (32), `00 F5` |
| **Never send:** format card, factory reset, delete clip | `5A 07…`, `5A 08…`, `5A 80…` |

| From the fan | |
|---|---|
| `5A 86 …` (11 bytes, every second) | status; byte 4 is the brightness |
| `5A 8D …` | device info: its name, MAC (`a0:dd:6c:…`, an ESP32), the router it was told to join |
| `5A 84 …` | file list, names separated by `/` |

**Joining a home network:** the fan stores the network (it shows in its `5A 8D` info) but didn't connect to the home Wi-Fi tried on 4 Oct, through the app or this tool, even after a restart. It's 2.4 GHz only; try a 2.4 GHz WPA2 network. Until then, the brain would reach it on its own network through a second Wi-Fi adapter.

## Uploads (not done)

What's known from the decompile:
- Upload start: `5A 84 <name length> <name> … F5`; the app then waits for the fan's answer (state 12, which is what "code:12" reports when it never comes).
- The data goes in chunks of 11,680 bytes; each frame has a 4-byte length header (`fileprocess::sendgroupdata`, `sendTo`), then `transfinish`.
- Images and video are converted for the fan by a per-model encoder: the app supports about 30 fan models; the PD42 looks like the `hs42l` family (`fileprocess::hs42lpicprocess`, `pictohs42lbin`, `matToQbytes`: a polar warp to the LED arm and a custom bit layout).

Next: record one real upload through a relay (the fan connects to the controller, the controller connects on to the app; see [`relay.py`] in the session notes), then write the encoder against it.
