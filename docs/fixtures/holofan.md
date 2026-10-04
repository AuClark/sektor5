# Hologram fan (PD42)

A 42 cm LED hologram fan ("3D Holographic Fan", model **PD42**, 1024 × 640, app **Holoscope**). It shows clips stored on its microSD card. The goal: showbrain picks and plays clips with the show. Tool: [`fixtures/holofan/holofan.py`](../../fixtures/holofan/holofan.py).

**Status (4 Oct 2026):** controlled from a Mac on the fan's Wi-Fi: it connects, stays connected, reports its status and file list, and takes brightness changes (confirmed in its status). Play / pause / clip / power use the same framing but haven't been tried live yet. Uploading new content isn't done yet; the encoder is partly decoded (see [Uploads](#uploads-not-done)). Not a showbrain fixture yet.

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

### The PD42's encoder (partly read)

The fan reports its model in byte 8 of its `5A 86` status: the PD42 is **model 15** (`0x0F`). Models 7, 15, 0x1E and 0x1F use the `hs42l` path (`fileprocess::run` → `hs42lpicprocess` → `pictohs42lbin`). For model 15, `setparam` gives: rate 12.0, brightness scale 1.6, and the settings (490, 122, 6, 16000): 490 angle steps per turn, 122 LEDs per arm, 6 hub pixels blanked, 16 kHz audio.

A picture, in order (`hs42lpicprocess`):
1. `5A 84 <len> <name> … F5`, then wait up to 5 s for the fan to say the file is created (re-sent after 2 s; "code:12" is this timing out).
2. A 4-byte little-endian header: rate × 5 (60 for the PD42).
3. The image, read as OpenCV BGR, copied into a frame of the model's size, then `pictohs42lbin`:
   - optional BGR→RGB (`cvtColor` 4) by colour mode; optional rotation in 90° steps;
   - `warpPolar` (linear, Lanczos, outliers filled) to 122 × 490: radius along the row, angle down the rows; centre and radius from the image;
   - brightness: the mean grey × 1.6, capped at 150, becomes the target mean (`cvConvertScale`);
   - radial correction on the first 16 pixels from the hub (bytes 0–47 of each row): ×0.73 (bytes 0–18), 0.74 (19–23), 0.77 (24–26), 0.80, 0.83, 0.86, 0.89, 0.92 (39–44), 0.98 (45–47);
   - the first 6 pixels (the hub) blanked;
   - the two arms combined into one frame: each output row is one angle row for arm A and the opposite row for arm B (122 LEDs each), through per-channel 256-entry tables (`+0xc264`, `+0xc364`, `+0xc464`, likely gamma);
   - packed as **bit planes**: each output byte holds one bit of an LED's R, G and B at scattered positions (`4, 2, 0x40, 0x20, 8, 1, 0x80`), in groups of 88 and 80; 264 bytes per angle row in the branch that looks like the PD42's. There are three branches (×0x20 per row for model 0x1E; 288 and 264 bytes per row for others); which one model 15 takes isn't confirmed.
4. Sent in 11,680-byte chunks (`sendTo`), each frame with a 4-byte length header (`sendgroupdata`); then `transfinish` once every chunk is acknowledged.

Still to do: confirm model 15's packing branch and port it exactly; find where the three tables are filled; the `transfinish` packet and the fan's acknowledgements; then upload a test picture. Recording one real upload (the fan connects to the controller, which connects on to the app) would let each step be checked against the app's own output.
