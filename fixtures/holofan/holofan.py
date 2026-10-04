#!/usr/bin/env python3
"""Control a PD42 "Holoscope" 3D hologram fan without its app.

The fan finds its controller, not the other way round: the controller broadcasts "<its IP>HS" on UDP 8988
(the app does it every 2.5 s) and the fan connects back to it on TCP 6666. Commands are then raw bytes on
that connection: 5A <cmd> [arg] <check> F5 (check = the last byte before F5 repeated), from Holoscope 2.5.2.

    holofan.py listen [secs]              # announce, wait for the fan, print what it sends
    holofan.py run CMD [CMD ...]          # e.g. run on bright:200 play:0 play loopall
    holofan.py join "SSID" "PASSWORD"     # move the fan onto a Wi-Fi network (2.4 GHz)

CMDs: on off play pause loop1 loopall bright:N(0-255) clip:N volume:N
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
    v = int(v)
    if k == "bright": return frame(0x81, max(0, min(255, v)))
    if k == "clip": return frame(0x87, v + 1)
    if k == "volume": return frame(0x90, max(0, min(255, v)))
    raise SystemExit(f"unknown command {c!r}")


def join_frame(ssid, pw):
    b = bytearray(0x44); b[0], b[1] = 0x5A, 0x8B
    s, p = ssid.encode()[:32], pw.encode()[:32]
    b[2:2 + len(s)] = s; b[0x22:0x22 + len(p)] = p; b[-1] = 0xF5
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


HEARTBEAT, HELLO = bytes([0x5A, 0x0D, 0x0D, 0xF5, 0x00]), bytes([0x5A, 0x1C, 0x1C, 0xF5, 0x00])   # as the app's MyTcpServer::timer_out


def keepalive(conn, stop, every=1.0):
    """The fan hangs up after a few seconds without these."""
    try:
        conn.sendall(HELLO)
        while not stop.is_set():
            conn.sendall(HEARTBEAT); stop.wait(every)
    except OSError:
        pass


def reader(conn, log=print):
    conn.settimeout(0.5)
    while True:
        try:
            d = conn.recv(4096)
            if not d: log("fan closed the connection"); return
            log(f"fan -> {len(d)} B: {d[:64].hex(' ')}{' ...' if len(d) > 64 else ''}")
        except socket.timeout:
            continue
        except OSError:
            return


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
    elif mode == "join":
        f = join_frame(sys.argv[2], sys.argv[3]); print(f"send join {sys.argv[2]!r}: {f[:2].hex(' ')} ... ({len(f)} B)"); conn.sendall(f)
    time.sleep(3); conn.close()


if __name__ == "__main__":
    main()
