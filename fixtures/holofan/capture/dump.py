#!/usr/bin/env python3
"""Print a relay.py recording: one line per read, or with --join the two directions reassembled into files
(<rec>.app2fan.bin, <rec>.fan2app.bin) so the upload's bytes can be compared with the source image."""
import struct, sys

def records(path):
    d = open(path, "rb").read(); i = 0
    while i + 13 <= len(d):
        t, direction, n = struct.unpack_from("<dBI", d, i); i += 13
        yield t, direction, d[i:i + n]; i += n

def main():
    args = [a for a in sys.argv[1:] if a != "--join"]
    path = args[0] if args else "relay.bin"
    recs = list(records(path))
    if "--join" in sys.argv:
        for direction, tag in ((1, "app2fan"), (0, "fan2app")):
            data = b"".join(r for _, d, r in recs if d == direction)
            open(f"{path}.{tag}.bin", "wb").write(data); print(f"{path}.{tag}.bin: {len(data)} bytes")
        return
    t0 = recs[0][0] if recs else 0
    for t, direction, data in recs:
        print(f"{t - t0:8.2f} {'app->fan' if direction else 'fan->app'} {len(data):6} {data[:32].hex(' ')}")

if __name__ == "__main__":
    main()
