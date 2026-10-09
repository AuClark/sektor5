# Mask eyes

The DJ's mask (a 3D-printed Wendigo skull or a Guy Fawkes mask; the electronics move between them) has two LED eyes. It's an `eyes` fixture in the show engine: both eyes follow the par can's wash, with the same colour, the same hits and the same white flash on the drop.

## Hardware

| Part | Notes |
|---|---|
| 2 × LED board | 36 × 12 mm, 3 × SK9822 (OPSCO SK9822-001, LCSC C2829089) each, GH 4-pin input (1 VCC, 2 DI, 3 CI, 4 GND) |
| Waveshare ESP32-C3-Zero | WLED 16.0.1, mDNS `s5-mask`, name "Mask" |
| SN74AHCT125N | 3.3 V → 5 V level shifter, piggybacked on the back of the C3-Zero |
| 10000 mAh USB-C power bank | Powers everything through the C3's USB-C |

- **Chain:** C3 → 74AHCT125 → board 1 (LEDs 0-2) → board 2 (LEDs 3-5). Board 1's last LED (D3) pins 6 (DO) and 5 (CO) are soldered to board 2's DI and CI.
- **Signals:** data on GPIO 10 into the chip's pin 2 (1A), out on pin 3 (1Y); clock on GPIO 20 into pin 5 (2A), out on pin 6 (2Y). Pins 1 and 4 (enables) go to GND; the unused buffers 3 and 4 are switched off (pins 10 and 13 to 5 V) with their inputs (pins 9 and 12) grounded.
- **Why the level shifter:** the SK9822 needs 0.75 × VDD (3.75 V at 5 V) for a logic high. Straight from the C3's 3.3 V, frames were decoded wrongly: white showed as off, colours rotated, some patterns went dark.
- **Onboard LED:** the C3-Zero's own WS2812 is also on GPIO 10, so it shows garbage (usually white) while the eyes run. Harmless; tape over it.
- Six LEDs at full white draw about 360 mA.

## WLED

- LED output: `APA102` (type 51), data GPIO 10, clock GPIO 20, 6 LEDs, colour order **GRB** (checked with solid red), 1 MHz.
- Boot preset 1 "Mask red": the eyes come up dim red on power-up, and WLED returns to it when the show stops streaming (IDLE).
- Setting individual LEDs through the JSON API (`"i"`) freezes the segment. Send `"frz": false` before effects or colours, or nothing changes.

## In the show

`brain/showbrain/config.json`:

```json
{"name": "mask", "kind": "eyes", "host": "${S5_MASK_HOST:-s5-mask.local}", "leds": 6, "brightness": 0.6, "role": {"pos": 0}}
```

The look is `eyes()` in `brain/showbrain/looks.py`: the par can's colour on every LED, with its white channel folded into RGB (amber and UV are left out). Strobe, blinder and blackout from the Commander apply as on every other fixture. Turn it off or down per fixture in the Commander like the others.

The mask runs on the venue Wi-Fi, the same as the tubes. If it walks out of range, the brain keeps sending and WLED falls back to its red boot look.
