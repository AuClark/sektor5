#!/usr/bin/env python3
"""Control a PD42 "Holoscope" 3D hologram fan without its app.

The fan finds its controller, not the other way round: the controller broadcasts "<its IP>HS" on UDP 8988
(the app does it every 2.5 s) and the fan connects back to it on TCP 6666. Commands are then raw bytes on
that connection: 5A <cmd> [arg] <check> F5 (check = the last byte before F5 repeated), from Holoscope 2.5.2.

    holofan.py listen [secs]              # announce, wait for the fan, print what it sends
    holofan.py run CMD [CMD ...]          # e.g. run on bright:200 play:0 play loopall
    holofan.py join "SSID" "PASSWORD"     # move the fan onto a Wi-Fi network (2.4 GHz)
    holofan.py upload PICTURE [--play]    # convert a picture (encode.py) and add it to the fan's clips

CMDs: on off play pause loop1 loopall bright:N(0-255) clip:N volume:N master:on|off
Never sent (destructive): format card (07), factory reset (08), delete clip (80).

Run it on the fan's own Wi-Fi (SSID 3D-PD42-..., default password 12345678; the fan is 192.168.4.1), or on a
network the fan has joined. Only one controller at a time: close the Holoscope app first.
See docs/fixtures/holofan.md.
"""
import socket, sys, threading, time

UDP_PORT, TCP_PORT = 8988, 6666


def my_ip(target="192.168.4.1"):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect((target, 1)); return s.getsockname()[0]
    finally:
        s.close()


def frame(cmd, arg=None):
    body = [0x5A, cmd] + ([] if arg is None else [arg & 0xFF])
    return bytes(body + [body[-1], 0xF5])


COMMANDS = {"on": frame(0x01), "off": frame(0x02), "pause": frame(0x03), "play": frame(0x04),
            "loop1": frame(0x05), "loopall": frame(0x06)}


def parse(c):
    if c in COMMANDS:
        return COMMANDS[c]
    k, _, v = c.partition(":")
    v = {"on": 1, "off": 0}.get(v, v); v = int(v)
    if k == "bright": return frame(0x81, max(0, min(255, v)))
    if k == "clip": return frame(0x87, v + 1)
    if k == "volume": return frame(0x90, max(0, min(255, v)))
    if k == "master": return frame(0x1F if v else 0x20)       # DeviceInterface::master(bool); untested what it changes
    raise SystemExit(f"unknown command {c!r}")


def join_frame(ssid, pw):
    b = bytearray(0x44); b[0], b[1] = 0x5A, 0x8B
    s, p = ssid.encode()[:32], pw.encode()[:32]
    b[2:2 + len(s)] = s; b[0x22:0x22 + len(p)] = p
    b[-2] = xor(b[2:-2]); b[-1] = 0xF5        # DeviceInterface::routerset (5A 8A, wifiset, renames the fan's own AP)
    return bytes(b)


def wait_for_fan(timeout=60, log=print):
    ip = my_ip()
    srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", TCP_PORT)); srv.listen(1); srv.settimeout(1.0)
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); udp.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    udp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try: udp.bind(("0.0.0.0", UDP_PORT))          # the app sends from 8988 too
    except OSError: pass
    msg = (ip + "HS").encode()
    bcast = ip.rsplit(".", 1)[0] + ".255"
    log(f"announcing {msg.decode()} on UDP {UDP_PORT}, waiting on TCP {TCP_PORT}")
    t0 = time.time()
    while time.time() - t0 < timeout:
        for dst in (bcast, "255.255.255.255"):
            try: udp.sendto(msg, (dst, UDP_PORT))
            except OSError: pass
        try:
            conn, addr = srv.accept()
            log(f"fan connected from {addr[0]}:{addr[1]}"); srv.close(); return conn
        except socket.timeout:
            pass
    srv.close(); return None


SEND = threading.Lock()                         # held for a whole upload: no heartbeats inside the data
CREATED = threading.Event()                     # the fan's "file created" (5A 0E 0E F5)
FILES = []                                      # the fan's latest file list (names without extension)

HEARTBEAT, HELLO = bytes([0x5A, 0x0D, 0x0D, 0xF5, 0x00]), bytes([0x5A, 0x1C, 0x1C, 0xF5, 0x00])   # as the app's MyTcpServer::timer_out


def keepalive(conn, stop, every=1.0):
    """The fan hangs up after a few seconds without these."""
    try:
        with SEND: conn.sendall(HELLO)
        while not stop.is_set():
            with SEND: conn.sendall(HEARTBEAT)
            stop.wait(every)
    except OSError:
        pass


def reader(conn, log=print):
    conn.settimeout(0.5)
    while True:
        try:
            d = conn.recv(4096)
            if not d: log("fan closed the connection"); return
            if b"\x5a\x0e\x0e\xf5" in d: CREATED.set()
            i = d.find(b"\x5a\x84")                 # file list: 5A 84 <length, 16-bit BE> <names joined by /> 00 F5
            if i >= 0 and len(d) > i + 4:
                n = int.from_bytes(d[i + 2:i + 4], "big")
                FILES[:] = [x.decode("utf-8", "replace") for x in d[i + 4:i + 4 + n].rstrip(b"\x00").split(b"/")]
            log(f"fan -> {len(d)} B: {d[:64].hex(' ')}{' ...' if len(d) > 64 else ''}")
        except socket.timeout:
            continue
        except OSError:
            return


def xor(b):
    x = 0
    for c in b: x ^= c
    return x


def start_frame(name):
    """5A 84 <len> <name> <xor of len and name> F5: asks the fan to create the file."""
    body = bytes([len(name)]) + name.encode()
    return b"\x5a\x84" + body + bytes([xor(body), 0xF5])


def finish_frame(n=0):
    """5A 91 <n, 32-bit BE> <xor> F5. The app puts the last video's frame count - 1 here even for pictures, so the
    fan doesn't seem to use it for pictures."""
    v = n.to_bytes(4, "big")
    return b"\x5a\x91" + v + bytes([xor(v), 0xF5])


PICTURE_HEADER = (60).to_bytes(4, "little")     # model 15: rate 12.0 x 5


def upload(conn, frames, header=PICTURE_HEADER, name=None, n=0, log=print):
    """Send encoded frames as one new clip; returns its name (as the fan lists it, without .mp4)."""
    name = name or time.strftime("%d%H%M%S") + ".mp4"   # as the app names them
    with SEND:
        CREATED.clear()
        for attempt in range(3):                # the app re-sends after 2 s and gives up at 5 ("code:12")
            conn.sendall(start_frame(name))
            if CREATED.wait(2.0): break
        else:
            raise RuntimeError("the fan never said the file was created")
        log(f"fan created {name}; sending {len(frames)} bytes")
        conn.sendall(header + frames)
        for _ in range(3):
            time.sleep(0.5); conn.sendall(finish_frame(n))
    log("upload sent")
    return name.rsplit(".", 1)[0]


def play_new(conn, name, wait=10, log=print):
    """Pick the uploaded clip by name from the fan's file list and play it."""
    t0 = time.time()
    while name not in FILES and time.time() - t0 < wait:
        time.sleep(0.5)
    if name not in FILES:
        log(f"{name} isn't in the fan's file list yet"); return
    idx = FILES.index(name)
    for c in ("on", f"clip:{idx}", "play"):
        f = parse(c); log(f"send {c}: {f.hex(' ')}")
        with SEND: conn.sendall(f)
        time.sleep(1.0)


def main():
    if len(sys.argv) < 2: print(__doc__); return
    mode = sys.argv[1]
    conn = wait_for_fan(int(sys.argv[2]) if mode == "listen" and len(sys.argv) > 2 else 60)
    if not conn: print("no fan connected"); sys.exit(1)
    threading.Thread(target=reader, args=(conn,), daemon=True).start()
    stop = threading.Event(); threading.Thread(target=keepalive, args=(conn, stop), daemon=True).start()
    time.sleep(2)                                   # let it say hello
    if mode == "run":
        for c in sys.argv[2:]:
            f = parse(c); print(f"send {c}: {f.hex(' ')}"); conn.sendall(f); time.sleep(1.5)
    elif mode == "upload":
        import cv2, encode                      # numpy + opencv only needed here
        img = cv2.imread(sys.argv[2])
        if img is None: print(f"can't read {sys.argv[2]}"); sys.exit(1)
        name = upload(conn, encode.encode_image(img))
        if "--play" in sys.argv: time.sleep(2); play_new(conn, name)
    elif mode == "join":
        f = join_frame(sys.argv[2], sys.argv[3]); print(f"send join {sys.argv[2]!r}: {f[:2].hex(' ')} ... ({len(f)} B)"); conn.sendall(f)
    time.sleep(3); conn.close()


if __name__ == "__main__":
    main()
