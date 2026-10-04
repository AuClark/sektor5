#!/usr/bin/env python3
"""Turn a picture into the PD42 hologram fan's frame format (model 15), as the Holoscope app does.

One frame is 141,120 bytes: the fan's 490 angle rows, taken as 245 pairs of opposite rows (one per arm), each pair
packed as 6 bit planes x 96 bytes. Steps, from the app (fileprocess::pictohs42lbin) and checked against a recorded
upload (docs/fixtures/holofan.md):
  polar warp (122 LEDs x 490 angles, centre = image centre, radius = half the shorter side, Lanczos)
  -> brightness: scale so the mean grey becomes min(mean x 1.6, 150)
  -> dim the 16 pixels nearest the hub, blank the first 6
  -> colour table v^3 / 255^2 (the fan keeps the top 6 bits)
  -> bit planes.
Needs numpy and opencv-python(-headless).

  encode.py picture.png out.bin        write one frame
  encode.py --decode frame.bin out.png  turn a frame back into a flat image (for checking)
"""
import sys
import numpy as np
import cv2

ROWS, LEDS, HUB = 490, 122, 6          # model 15: angle steps per turn, LEDs per arm, hub pixels blanked
PAIRS = ROWS // 2
FRAME_BYTES = ROWS * 288
BRIGHT_SCALE, BRIGHT_CAP = 1.6, 150.0
HUB_DIM = [(0, 19, .73), (19, 24, .74), (24, 27, .77), (27, 30, .80), (30, 33, .83),   # (first byte, end byte, factor)
           (33, 36, .86), (36, 39, .89), (39, 42, .92), (42, 45, .95), (45, 48, .98)]                # over the row's B,G,R bytes
TABLE = (np.arange(256, dtype=np.uint32) ** 3 // (255 * 255)).astype(np.uint8)


def to_polar(img):
    """BGR image -> (490, 122, 3) polar rows as the fan's arm sees them, before packing."""
    h, w = img.shape[:2]
    p = cv2.warpPolar(img, (LEDS, ROWS), (w / 2, h / 2), min(w, h) / 2,
                      cv2.WARP_POLAR_LINEAR | cv2.INTER_LANCZOS4 | cv2.WARP_FILL_OUTLIERS)
    grey = cv2.cvtColor(p, cv2.COLOR_BGR2GRAY).mean()
    if grey > 0:
        p = cv2.convertScaleAbs(p, alpha=min(grey * BRIGHT_SCALE, BRIGHT_CAP) / grey)
    f = p.reshape(ROWS, LEDS * 3).astype(np.float64)
    for a, b, k in HUB_DIM:
        f[:, a:b] = np.floor(f[:, a:b] * k)
    p = f.astype(np.uint8).reshape(ROWS, LEDS, 3)
    p[:, :HUB] = 0
    return TABLE[p]


def _arms(polar):
    """(245, 368) byte rows for arm A (polar row 489 - r) and arm B (polar row 244 - r); 2 spare zero bytes each."""
    r = np.arange(PAIRS)
    a = np.zeros((PAIRS, 368), np.uint8); b = np.zeros((PAIRS, 368), np.uint8)
    a[:, :366] = polar[ROWS - 1 - r].reshape(PAIRS, -1)
    b[:, :366] = polar[PAIRS - 1 - r].reshape(PAIRS, -1)
    return a, b


# Output bit -> (arm, source byte offset) for the byte at position j of a plane: loop 1 uses p = 95 - j over source
# bytes 0..191, loop 2 uses the same index over bytes 192..367 (only for j >= 8).
_LOOP1 = {3: (0, 0), 0: (1, 0), 7: (0, 1), 4: (1, 1)}
_LOOP2 = {2: (0, 192), 1: (1, 192), 6: (0, 193), 5: (1, 193)}


def pack(polar):
    """(490, 122, 3) polar -> one 141,120-byte frame."""
    arms = _arms(polar)
    out = np.zeros((PAIRS, 6, 96), np.uint8)
    j = np.arange(96); p = 95 - j
    for plane in range(6):
        bit = 7 - plane
        for outbit, (arm, off) in _LOOP1.items():
            out[:, plane, :] |= ((arms[arm][:, off + 2 * p] >> bit) & 1) << outbit
        for outbit, (arm, off) in _LOOP2.items():
            src = ((arms[arm][:, off + 2 * p[8:]] >> bit) & 1) << outbit
            out[:, plane, 8:] |= src.astype(np.uint8)
    return out.tobytes()


def unpack(frame):
    """One frame -> (490, 122, 3) polar (top 6 bits of each value)."""
    d = np.frombuffer(frame[:FRAME_BYTES], np.uint8).reshape(PAIRS, 6, 96)
    arms = [np.zeros((PAIRS, 368), np.uint8), np.zeros((PAIRS, 368), np.uint8)]
    j = np.arange(96); p = 95 - j
    for plane in range(6):
        bit = 7 - plane
        for outbit, (arm, off) in _LOOP1.items():
            arms[arm][:, off + 2 * p] |= ((d[:, plane, :] >> outbit) & 1) << bit
        for outbit, (arm, off) in _LOOP2.items():
            arms[arm][:, off + 2 * p[8:]] |= ((d[:, plane, 8:] >> outbit) & 1) << bit
    polar = np.zeros((ROWS, LEDS, 3), np.uint8)
    r = np.arange(PAIRS)
    polar[ROWS - 1 - r] = arms[0][:, :366].reshape(PAIRS, LEDS, 3)
    polar[PAIRS - 1 - r] = arms[1][:, :366].reshape(PAIRS, LEDS, 3)
    return polar


def encode_image(img):
    return pack(to_polar(img))


def flat(polar, size=512):
    return cv2.warpPolar(polar, (size, size), (size / 2, size / 2), size / 2,
                         cv2.WARP_POLAR_LINEAR | cv2.WARP_INVERSE_MAP | cv2.INTER_NEAREST)


def main():
    a = sys.argv[1:]
    if len(a) == 3 and a[0] == "--decode":
        cv2.imwrite(a[2], flat(unpack(open(a[1], "rb").read())))
    elif len(a) == 2:
        img = cv2.imread(a[0])
        if img is None:
            sys.exit(f"can't read {a[0]}")
        open(a[1], "wb").write(encode_image(img))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
