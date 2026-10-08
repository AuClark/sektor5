# Par can (DMX uplight)

A battery RGBWA+UV wireless-DMX uplight ("V6 APP Battery Wireless", 6 × 18 W 6-in-1; manual: [manuals/v6-battery-wireless-par-manual.pdf](../manuals/v6-battery-wireless-par-manual.pdf)), driven from the brain through an anyma uDMX USB adapter. It's a `dmx_par` fixture in the show engine. Code: [`brain/showbrain/dmx.py`](../../brain/showbrain/dmx.py) (show output) and [`fixtures/parcan/dmx.py`](../../fixtures/parcan/dmx.py) (one-off command-line sender).

## From the manual (verified 27 Sep 2026)

10-channel mode:

| Ch | Function |
|---|---|
| 1 | Master dimmer |
| 2 | Red |
| 3 | Green |
| 4 | Blue |
| 5 | White |
| 6 | Yellow (amber) |
| 7 | Purple (UV) |
| 8 | Strobe |
| 9 | Program: 0-8 = shut (manual colour control); 9-255 = built-in colour mixing / jump / pulse / gradual / sound modes |
| 10 | Program speed |

- **DMX mode:** Menu → `Slnd` → `Sl1` or `Sl2`. The display shows `stby` while it waits for DMX, cable or wireless. (`Nast` is stand-alone mode for the built-in programs.)
- **Wireless DMX** is 2.4 GHz radio and needs a separate wireless DMX transmitter on a DMX output. Turn on the signal switch; the indicator is red while waiting. Press the black ID button under it until its colour matches the transmitter's code; it blinks green once receiving.
- **Wi-Fi mode** (Shows → Wifi Mode) is for a phone app joining the light's own access point. It's a proprietary protocol, not DMX, and isn't used here.
- Battery: 3-4 h to full charge, and it can run while charging.

## In the show

The uDMX now plugs into the CM4 (`sektor5`) and the par can is a fixture in the show engine.
- The Pi sees the stick as `16c0:05dc`. `python3-usb` is installed, and a udev rule (`/etc/udev/rules.d/50-udmx.rules`) gives the `plugdev` group access, so the `pi` user can drive it without root.
- Show engine: `brain/showbrain/dmx.py` (a background sender that tolerates transient USB errors, reconnects, and resends every second as a keep-alive) plus the `par` look in `brain/showbrain/looks.py`.
- Fixture config (`brain/showbrain/config.json`): `"kind": "dmx_par"`, `"address": 1`, the channel map above, and `"delay_ms": 35`. USB DMX is near-instant, so it's delayed to land with the Wi-Fi fixtures.
- Channels 8 (strobe), 9 (program) and 10 (speed) are always sent as 0, so the light never runs its own programs.
- W / Amber / UV (channels 5-7) are confirmed by the manual and enabled via `"verified_extra": ["w", "a", "uv"]`.
- After a power outage the uDMX once dropped off USB with a kernel "disabled by hub (EMI?)" message, and a software reset didn't recover it; replugging did. The show engine reconnects automatically. Keep its cable away from the panel/strip power supplies, or use a powered hub.
- Only one program can own the uDMX at a time. Stop showbrain (`sudo systemctl stop showbrain`) before using `dmx.py` or the Light Control app against it.

## The light
Battery-powered wireless DMX uplight (black box, "WIRELESS DMX CODE" button, IR receiver, colour LCD, buttons MENU / UP / DOWN / ENTER).
Main menu: Dmx512, Shows, Sound, Color, Set, Help.
Current setting: **Dmx512 mode, address A001, 10CH mode.** Wired DMX works; wireless DMX isn't tested yet.
If the display shows anything other than `A001` (e.g. `AC:02`, one of its own colour programs; static colour 2 is solid blue), it's out of DMX mode and ignores the show: Menu → Dmx512 → A001 → Enter. The show side can't tell (DMX is one-way), so check the display first when the par can doesn't react.

## uDMX protocol (what works)
- Control transfer, bmRequestType 0x40 (vendor, device, host-to-device)
- bRequest 2 = SetChannelRange: wValue = number of channels, wIndex = first channel (0-based), data = channel values (bytes)
- bRequest 1 = SetSingleChannel: wValue = value, wIndex = channel (0-based)
- The uDMX keeps outputting the last values it was sent.

## Original bench setup (Mac)

The light was first brought up from a MacBook on 26 Sep 2026. That setup, including a "Light Control" web app in `~/Lights` on that Mac, **isn't part of this repo**. It's kept here for reference.

### Hardware chain
MacBook Air (Apple Silicon, macOS, Python 3.13 at /Library/Frameworks/Python.framework)
  then UGREEN USB-C multiport hub (GenesysLogic hub, VID 0x05e3; also has card reader + ASIX AX88179B ethernet)
  then **anyma uDMX** USB-to-DMX adapter (silver stick in the hub's USB 3.0 port)
      - Manufacturer: www.anyma.ch, Product: uDMX, Serial: ilLUTZminator001
      - USB VID 0x16c0, PID 0x05dc, USB 1.1 low speed
      - NOT a serial port (no /dev/cu.* device). Must be driven with libusb vendor control transfers.
  then DMX cable into the light.

### Software installed on the Mac
- `brew install libusb` (at /opt/homebrew/lib/libusb-1.0.dylib)
- Python venv at `~/.udmx-venv` with `pyusb`
- `dmx.py`: command-line sender, e.g. `~/.udmx-venv/bin/python dmx.py 255 0 0 255 0 0 0 0 0 0` (blue)

### Light Control app (on that Mac, not in this repo)
- **Double-click `Light Control.command`** to (re)start the server and open http://localhost:8765
- `server.py`: 40 fps output engine (fades + effects), auto-reconnects to the uDMX, and saves state and scenes to `lights.json`
  - Run with `--lan` to control it from a phone on the same Wi-Fi (it prints the address)
  - The uDMX throws an occasional transient USB I/O error (~1 in 10 transfers at high rates). The server tolerates these and only drops the handle after 20 failures in a row or "no such device".
- `index.html`: the UI. Live preview orb, brightness, 12 colour presets, hue/saturation pad (pastels go to the white LED), W/Amber/UV sliders, effects (Rainbow, Breathe, Strobe, Candle, Police, Party) with speed, fade time, named scenes, raw channel sliders.
- Keys: Space = blackout, 1-0 = presets, Up/Down = brightness, E = next effect, Esc = stop effect
- API: `GET /state`, `GET /events` (server-sent events), `POST /api` with JSON such as
  `{"patch":{"1":255}, "fade":500}`, `{"values":[...10]}`, `{"effect":"rainbow","speed":0.5}`, `{"blackout":"toggle"}`,
  `{"save_scene":"Name"}`, `{"recall_scene":"Name"}`, `{"delete_scene":"Name"}`. The old `POST /set` with a 10-value array still works.
- The original v1 is still in `~/udmx`.

### Ideas for next steps
- Verify channels 3 and 5 to 10 (use "All channels" in the UI)
- Multiple fixtures at different addresses
- Sound-reactive mode (mic input), timers/schedules
- Alternatively use QLC+ (supports uDMX natively)
