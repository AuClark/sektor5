#!/usr/bin/env python3
"""Sit between the PD42 fan and the Holoscope app and record everything (for learning the upload format).
Records go to the file named on the command line (default relay.bin) as <double t><byte dir: 0=fan->app, 1=app->fan><uint32 len><data>."""
import select, socket, struct, sys, time
import os; sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")); import holofan as h

LOG = open(sys.argv[1] if len(sys.argv) > 1 else "relay.bin", "wb")
def rec(d, data): LOG.write(struct.pack("<dBI", time.time(), d, len(data)) + data); LOG.flush()
def say(*a): print(time.strftime("%H:%M:%S"), *a, flush=True)

me = h.my_ip("192.168.4.1"); t0 = time.time(); LIMIT = 360
udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
udp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); udp.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
try: udp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
except Exception: pass
udp.bind(("0.0.0.0", h.UDP_PORT)); udp.setblocking(False)
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); srv.bind(("0.0.0.0", h.TCP_PORT)); srv.listen(1); srv.setblocking(False)
fan = app = None; phone = None; fanbuf = b""; last_ann = last_hb = 0; total = 0; last_data = time.time()
say(f"relay on {me}: announcing until the fan connects")
while time.time() - t0 < LIMIT:
    now = time.time()
    if fan is None and now - last_ann > 0.3:
        for dst in ("192.168.4.255", "255.255.255.255"):
            try: udp.sendto((me + "HS").encode(), (dst, h.UDP_PORT))
            except OSError: pass
        last_ann = now
    if fan is not None and app is None and now - last_hb > 1.0:
        try: fan.sendall(h.HEARTBEAT)                 # keep the fan with us until the app is relayed
        except OSError: say("fan dropped before the app came"); break
        last_hb = now
    socks = [udp] + ([srv] if fan is None else []) + [s for s in (fan, app) if s]
    r, _, _ = select.select(socks, [], [], 0.1)
    for s in r:
        if s is udp:
            try:
                d, a = udp.recvfrom(256)
                if d.endswith(b"HS") and a[0] != me and phone is None:
                    phone = a[0]; say(f"the app announced from {phone}")
            except OSError: pass
        elif s is srv:
            fan, fa = srv.accept(); say(f"fan connected from {fa[0]}: stopped announcing")
        elif s is fan:
            d = fan.recv(65536)
            if not d: say("fan closed"); fan = None; break
            rec(0, d); total += len(d); last_data = now
            if app: app.sendall(d)
            else: fanbuf += d[-4096:]
        elif s is app:
            d = app.recv(65536)
            if not d: say("app closed"); app = None; break
            rec(1, d); total += len(d); last_data = now
            if fan: fan.sendall(d)
    else:
        if fan is not None and app is None and phone:
            try:
                app = socket.create_connection((phone, h.TCP_PORT), 3); say(f"connected to the app at {phone}:{h.TCP_PORT}: relaying")
                if fanbuf: app.sendall(fanbuf); fanbuf = b""
            except OSError as e:
                say("can't reach the app yet:", e); phone = None
        if app and total > 200000 and now - last_data > 45:
            say("upload looks done (45 s quiet after a big transfer)"); break
        continue
    break
say(f"recorded {total} bytes in {time.time() - t0:.0f} s")
