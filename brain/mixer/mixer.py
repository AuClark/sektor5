#!/usr/bin/env python3
"""DJM-450 mixer bridge: post-fader channel levels, master level and MIDI over USB.

The DJM-450's USB sound card exposes capture sources (ALSA card "DJM450"):
  Input 1 -> capture ch 1/2   set to "Post Fader"  (mixer channel 1, after its fader)
  Input 2 -> capture ch 3/4   set to "Post Fader"  (mixer channel 2, after its fader)
  Input 3 -> capture ch 5/6   set to "Rec Out"     (the master mix)
It only streams capture while a playback stream is open (implicit feedback), so we
also play silence to it. The decks' channels are on LINE, so that silence isn't heard.

Every 50 ms it sends a JSON "mixer" message over UDP to deckdash (:9101) and showbrain
(:9100) with RMS/peak dB per channel, each channel's share of the mix, recent MIDI, an
analysis of the master mix ("audio": bass/mid/high energy, kicks, bass out, and "melody": chroma,
the lead note, brightness and synth onsets, for the laser show) and the set
recorder's state ("rec").

The recorder writes the master mix (Rec Out) to S5_REC_DIR (default /srv/rave/recordings)
as FLAC (WAV if flac isn't installed) whenever music plays: it starts after 3 s of sound
(keeping 3 s of pre-roll) and stops after 90 s of silence. Next to each recording it keeps a
tracklist (.txt and .cue) of the deck the lights follow, from deckdash's /api/state.
S5_REC=off turns it off (the old RAVE_REC names still work).

    python3 brain/mixer/mixer.py
"""
import collections
import json
import math
import os
import shutil
import socket
import subprocess
import threading
import time
import urllib.request
import wave
from pathlib import Path

import numpy as np

CARD = "DJM450"
RATE, CH, BLOCK_S = 48000, 8, 0.05
TARGETS = [("127.0.0.1", 9101), ("127.0.0.1", 9100)]
SOURCES = {"Input 1": "Post Fader", "Input 2": "Post Fader", "Input 3": "Rec Out"}
SILENCE_DB = -70.0

midi_log = []          # recent MIDI messages (hex strings), newest last
midi_lock = threading.Lock()
midi_count = 0


def log(msg):
    print(time.strftime("%X"), msg, flush=True)


def card_present():
    try:
        return CARD in open("/proc/asound/cards").read()
    except OSError:
        return False


def set_sources():
    for ctl, val in SOURCES.items():
        subprocess.run(["amixer", "-c", CARD, "-q", "sset", ctl, val], check=False)


def midi_reader():
    """Collect raw MIDI from the DJM (amidi -d prints hex bytes)."""
    global midi_count
    while True:
        port = None
        try:
            out = subprocess.run(["amidi", "-l"], capture_output=True, text=True).stdout
            port = next((l.split()[1] for l in out.splitlines() if "DJM-450" in l), None)
        except OSError:
            pass
        if not port:
            time.sleep(3)
            continue
        p = subprocess.Popen(["amidi", "-p", port, "-d"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        for line in p.stdout:
            line = line.strip()
            if not line:
                continue
            with midi_lock:
                midi_count += 1
                midi_log.append({"t": round(time.time(), 2), "hex": line})
                del midi_log[:-20]
        time.sleep(1)


def db(x):
    return float(20 * np.log10(x + 1e-9))


# ---------------------------------------------------------------- master-mix analysis

class Stereo:
    """Left/right per stereo pair (ch1, ch2, master), smoothed over about a second: how alike the two
    sides are (corr: 1 = mono), how wide (width_db: side vs mid, near 0 = wide, under -30 = mono)
    and which side is louder (bal_db: + = left). Whole band and highs (2 kHz+, where the stereo in a
    club track lives: hats, percussion, effects). None while the pair is silent."""
    K = 0.1                                        # per 50 ms block: about 1 s

    def __init__(self):
        self.acc = [None, None, None]

    def update(self, pairs, active):
        out = {}
        for i, (name, p) in enumerate(zip(("ch1", "ch2", "master"), pairs)):
            if not active[i]:
                self.acc[i] = None
                out[name] = None
                continue
            L, R = p[:, 0].astype(np.float64), p[:, 1].astype(np.float64)
            hi = lambda v: np.fft.irfft(np.fft.rfft(v) * (np.fft.rfftfreq(len(v), 1 / RATE) >= 2000), n=len(v))
            Lh, Rh = hi(L), hi(R)
            e = np.array([L @ L, R @ R, L @ R, Lh @ Lh, Rh @ Rh, Lh @ Rh])      # energies and cross terms
            self.acc[i] = e if self.acc[i] is None else self.acc[i] * (1 - self.K) + e * self.K
            a = self.acc[i]
            def stats(ll, rr, lr):
                mid, side = (ll + rr + 2 * lr) / 4, (ll + rr - 2 * lr) / 4
                return {"corr": round(float(lr / (np.sqrt(ll * rr) + 1e-18)), 3),
                        "width_db": round(float(10 * np.log10((side + 1e-18) / (mid + 1e-18))), 1),
                        "bal_db": round(float(10 * np.log10((ll + 1e-18) / (rr + 1e-18))), 1)}
            out[name] = {**stats(a[0], a[1], a[2]), "highs": stats(a[3], a[4], a[5])}
        return out


class Melody:
    """What the synths and the melody are doing, from the master mix, for the laser show:
    chroma (how much of each of the 12 notes is sounding), the lead note (the strongest clear
    peak from 250 Hz to 2.5 kHz, as a MIDI number, when it stands out), brightness (spectral
    centroid, 0 dull .. 1 bright) and synth onsets (a jump in mid/high spectral flux). Uses the
    last ~170 ms of audio (8192 samples) for enough pitch resolution, updated every block."""

    N = 8192

    def __init__(self):
        self.buf = np.zeros(self.N, np.float32)
        self.win = np.hanning(self.N).astype(np.float32)
        f = np.fft.rfftfreq(self.N, 1 / RATE)
        self.f = f
        band = (f >= 110) & (f < 3520)
        self.chroma_idx = np.where(band)[0]
        self.chroma_pc = (np.round(12 * np.log2(f[band] / 440.0) + 69).astype(int)) % 12
        self.lead = np.where((f >= 250) & (f < 2500))[0]
        self.cent = (f >= 150) & (f < 8000)
        self.flux_band = (f >= 400) & (f < 8000)
        self.prev = None
        self.flux_avg = 0.0
        self.onset_ms = 0
        self.note = None

    def update(self, mono, active, now_ms):
        k = len(mono)
        self.buf = np.roll(self.buf, -k)
        self.buf[-k:] = mono[-self.N:]
        if not active:
            self.prev, self.note = None, None
            return {"chroma": [0.0] * 12, "note": None, "conf": 0.0, "bright": 0.0, "onset_ms": int(self.onset_ms)}
        mag = np.abs(np.fft.rfft(self.buf * self.win))
        pw = mag ** 2
        chroma = np.bincount(self.chroma_pc, weights=pw[self.chroma_idx], minlength=12)
        chroma = chroma / (chroma.max() + 1e-12)
        # The lead: the strongest peak in the melody band, refined between bins, if it stands out.
        seg = mag[self.lead]
        i = int(np.argmax(seg))
        conf = float(seg[i] / (np.median(seg) + 1e-9))
        j = self.lead[i]
        if 0 < j < len(mag) - 1:
            a, b, c = np.log(mag[j - 1:j + 2] + 1e-12)
            j = j + 0.5 * (a - c) / (a - 2 * b + c + 1e-12)
        freq = j * RATE / self.N
        midi = 69 + 12 * math.log2(max(freq, 1.0) / 440.0)
        self.note = round(midi) if conf > 8 else None
        bright = float((self.f[self.cent] * pw[self.cent]).sum() / (pw[self.cent].sum() + 1e-12))
        bright = min(1.0, max(0.0, math.log2(max(bright, 150) / 150) / math.log2(8000 / 150)))
        # Synth onset: the rise in the mid/high spectrum against its recent average.
        lm = np.log1p(mag[self.flux_band])
        if self.prev is not None:
            flux = float(np.maximum(lm - self.prev, 0).mean())
            if flux > 1.8 * self.flux_avg + 1e-3 and now_ms - self.onset_ms > 90:
                self.onset_ms = now_ms
            self.flux_avg += 0.08 * (flux - self.flux_avg)
        self.prev = lm
        return {"chroma": [round(float(v), 2) for v in chroma], "note": self.note, "conf": round(min(conf / 30, 1.0), 2),
                "bright": round(bright, 3), "onset_ms": int(self.onset_ms)}


class Analyser:
    """Bass / mid / high energy, kicks and "bass out" from the master mix, one 50 ms block at a time.

    Bass out compares the bass to the mids (so it doesn't depend on how loud the mix is) against a
    slow reference taken while the bass is in: it fires on an EQ kill, a filter or a bass-less
    breakdown, and clears when the bass comes back."""

    DROP_DB, BACK_DB = 10.0, 5.0            # bass-to-mid fall that counts as "out", and "back"

    def __init__(self, n):
        self.win = np.hanning(n).astype(np.float32)
        f = np.fft.rfftfreq(n, 1 / RATE)
        self.masks = {"low": (f >= 30) & (f < 150), "mid": (f >= 150) & (f < 2000), "high": (f >= 2000) & (f < 16000)}
        self.smooth = {}                    # band -> smoothed linear energy (~0.5 s)
        self.l_fast = 0.0
        self.prev_l = 0.0
        self.last_kick = 0
        self.ref = None                     # slow bass-to-mid reference (dB) while the bass is in
        self.heard = 0.0                    # seconds of audio seen, for the reference warm-up
        self.bass_out = False
        self.cand_since = None
        self.low_hist = collections.deque(maxlen=12)    # ~0.6 s: a beat, so gaps between kicks don't count
        self.melody = Melody()

    def update(self, mono, master_db, now_ms):
        spec = np.abs(np.fft.rfft(mono * self.win)) ** 2 / len(mono)
        e = {k: float(spec[m].sum()) + 1e-12 for k, m in self.masks.items()}
        for k, v in e.items():
            self.smooth[k] = v if k not in self.smooth else self.smooth[k] + 0.1 * (v - self.smooth[k])
        sm = {k: 10 * np.log10(v) for k, v in self.smooth.items()}
        active = master_db > -50

        # Kick: a jump in bass energy well above its recent average, at most one per 250 ms.
        low = e["low"]
        self.l_fast += 0.1 * (low - self.l_fast)
        if active and low > 1.6 * self.l_fast and low > self.prev_l and now_ms - self.last_kick > 250:
            self.last_kick = now_ms
        self.prev_l = low

        # Bass out: the loudest bass of the last beat against the mids, with a little hysteresis
        # in time so single blocks don't flicker it.
        self.low_hist.append(low)
        d = 10 * np.log10(max(self.low_hist)) - sm["mid"]
        if active:
            self.heard += BLOCK_S
            if self.ref is None:
                self.ref = d
            elif not self.bass_out:
                self.ref += 0.005 * (d - self.ref)          # ~10 s
        if active and self.ref is not None and self.heard > 4:
            want = d < self.ref - self.DROP_DB if not self.bass_out else d < self.ref - self.BACK_DB
            if want != self.bass_out:
                self.cand_since = self.cand_since or now_ms
                if now_ms - self.cand_since >= (200 if want else 100):
                    self.bass_out, self.cand_since = bool(want), None
            else:
                self.cand_since = None
        elif not active:
            self.bass_out, self.cand_since = False, None
        return {"low_db": round(sm["low"], 1), "mid_db": round(sm["mid"], 1), "high_db": round(sm["high"], 1),
                "kick_ms": int(self.last_kick), "bass_out": bool(self.bass_out),
                "level": round(min(1.0, max(0.0, (master_db + 40) / 30)), 3),
                "melody": self.melody.update(mono, active, now_ms)}


# ---------------------------------------------------------------- set recorder

class Recorder:
    START_DB, STOP_DB = -50.0, -60.0
    START_S, STOP_S, PREROLL_S = 3.0, 90.0, 3.0
    MIN_FREE = 2 * 1024 ** 3                # stop before the eMMC gets tight

    def __init__(self):
        self.enabled = os.environ.get("S5_REC", os.environ.get("RAVE_REC", "on")) != "off"
        self.dir = Path(os.environ.get("S5_REC_DIR", os.environ.get("RAVE_REC_DIR", "/srv/rave/recordings")))
        self.pre = collections.deque(maxlen=int(self.PREROLL_S / BLOCK_S))
        self.flac = self.wav = None
        self.name = self.error = None
        self.loud_since = self.quiet_since = None
        self.started = 0.0
        self.frames = 0
        self.tracks = []
        self.lock = threading.Lock()

    @property
    def on(self):
        return self.flac is not None or self.wav is not None

    def state(self):
        return {"on": self.on, "file": self.name, "secs": int(self.frames / RATE) if self.on else 0,
                "tracks": len(self.tracks), "enabled": self.enabled, "error": self.error}

    def feed(self, pcm, master_db, now):
        """pcm: one block of the master mix as 24-bit little-endian stereo."""
        if not self.enabled:
            return
        if not self.on:
            self.pre.append(pcm)
            if master_db > self.START_DB:
                self.loud_since = self.loud_since or now
                if now - self.loud_since >= self.START_S:
                    self._open(now)
            else:
                self.loud_since = None
            return
        self._write(pcm)
        if master_db < self.STOP_DB:
            self.quiet_since = self.quiet_since or now
            if now - self.quiet_since >= self.STOP_S:
                self.close("silence")
        else:
            self.quiet_since = None

    def _open(self, now):
        try:
            self.dir.mkdir(parents=True, exist_ok=True)
            if shutil.disk_usage(self.dir).free < self.MIN_FREE:
                raise OSError("less than 2 GB free")
            self.name = time.strftime("set-%Y-%m-%d-%H%M%S")
            if shutil.which("flac"):
                self.flac = subprocess.Popen(
                    ["flac", "--silent", "--force", "--endian=little", "--sign=signed", "--channels=2",
                     "--bps=24", f"--sample-rate={RATE}", "-5", "-o", str(self.dir / f"{self.name}.flac"), "-"],
                    stdin=subprocess.PIPE)
            else:
                self.wav = wave.open(str(self.dir / f"{self.name}.wav"), "wb")
                self.wav.setnchannels(2)
                self.wav.setsampwidth(3)
                self.wav.setframerate(RATE)
            self.error = None
        except OSError as e:
            self.error = f"can't record: {e}"
            self.enabled = False                # don't retry every block
            log(self.error)
            return
        self.started = now - len(self.pre) * BLOCK_S
        self.frames = 0
        self.tracks = []
        self.quiet_since = None
        for pcm in self.pre:
            self._write(pcm)
        self.pre.clear()
        log(f"recording {self.name}")
        threading.Thread(target=self._tracklist, args=(self.name,), daemon=True).start()

    def _write(self, pcm):
        try:
            if self.flac:
                self.flac.stdin.write(pcm)
            else:
                self.wav.writeframesraw(pcm)
            self.frames += len(pcm) // 6
        except (OSError, ValueError) as e:
            self.error = f"recording stopped: {e}"
            log(self.error)
            self.close("error")

    def close(self, why):
        with self.lock:
            name, secs = self.name, int(self.frames / RATE)
            try:
                if self.flac:
                    self.flac.stdin.close()
                    self.flac.wait(timeout=30)
                if self.wav:
                    self.wav.close()
            except (OSError, subprocess.TimeoutExpired):
                pass
            self.flac = self.wav = None
        if name:
            log(f"recording {name} closed ({why}): {secs // 60} min, {len(self.tracks)} tracks")

    def _tracklist(self, name):
        """While recording, note each track on the deck the lights follow (deckdash /api/state)."""
        last = None
        while self.on and self.name == name:
            try:
                with urllib.request.urlopen("http://127.0.0.1:8080/api/state", timeout=2) as r:
                    st = json.loads(r.read())
                show = st.get("show") or {}
                playing = [p for p in st.get("players", []) if p.get("status", {}).get("playing")]
                live = show.get("live") or (playing[0]["number"] if len(playing) == 1 else None)
                p = next((p for p in playing if p["number"] == live), None)
                t = p and p.get("track")
                if t and t.get("title") and (live, t["title"]) != last:
                    last = (live, t["title"])
                    self.tracks.append({"at": max(0.0, time.time() - self.started), "deck": live,
                                        "artist": t.get("artist") or "", "title": t["title"]})
                    self._write_tracklist(name)
            except Exception:
                pass
            time.sleep(2)

    def _write_tracklist(self, name):
        audio = f"{name}.flac" if self.flac else f"{name}.wav"
        txt = [f"{name}\n"]
        cue = [f'TITLE "{name}"', f'FILE "{audio}" WAVE']
        for i, t in enumerate(self.tracks, 1):
            s = int(t["at"])
            txt.append(f"{s // 3600:02d}:{s % 3600 // 60:02d}:{s % 60:02d}  {t['artist']} - {t['title']}  (deck {t['deck']})")
            q = lambda v: v.replace('"', "'")
            frames = int(t["at"] * 75)
            cue += [f"  TRACK {i:02d} AUDIO", f'    TITLE "{q(t["title"])}"', f'    PERFORMER "{q(t["artist"])}"',
                    f"    INDEX 01 {frames // 4500:02d}:{frames // 75 % 60:02d}:{frames % 75:02d}"]
        try:
            (self.dir / f"{name}.txt").write_text("\n".join(txt) + "\n")
            (self.dir / f"{name}.cue").write_text("\n".join(cue) + "\n")
        except OSError as e:
            log(f"tracklist: {e}")


def run():
    os.umask(0o002)                         # recordings stay readable/writable for the rave group
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    rec = Recorder()
    threading.Thread(target=midi_reader, daemon=True).start()
    while True:
        if not card_present():
            if rec.on:
                rec.close("mixer unplugged")
            msg = json.dumps({"t": "mixer", "ts": int(time.time() * 1000), "connected": False, "rec": rec.state()})
            for tgt in TARGETS:
                sock.sendto(msg.encode(), tgt)
            time.sleep(2)
            continue
        set_sources()
        dev = f"hw:{CARD},0"
        play = subprocess.Popen(["aplay", "-D", dev, "-f", "S24_3LE", "-c", str(CH), "-r", str(RATE), "-t", "raw", "-q", "/dev/zero"],
                                stderr=subprocess.DEVNULL)
        time.sleep(0.3)
        cap = subprocess.Popen(["arecord", "-D", dev, "-f", "S24_3LE", "-c", str(CH), "-r", str(RATE), "-t", "raw", "-q"],
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        log("capturing from DJM-450")
        n = int(RATE * BLOCK_S)
        blk = n * CH * 3
        peak_hold = np.full(3, SILENCE_DB)
        ana = Analyser(n)
        st = Stereo()
        try:
            while True:
                b = cap.stdout.read(blk)
                if len(b) < blk:
                    break
                a = np.frombuffer(b, np.uint8).reshape(-1, 3).astype(np.int32)
                si = a[:, 0] | (a[:, 1] << 8) | (a[:, 2] << 16)
                si = np.where(si >= 1 << 23, si - (1 << 24), si).reshape(-1, CH)
                s = si / float(1 << 23)
                # Stereo pairs -> ch1, ch2, master
                pairs = [s[:, 0:2], s[:, 2:4], s[:, 4:6]]
                rms = np.array([np.sqrt((p ** 2).mean()) for p in pairs])
                pk = np.array([np.abs(p).max() for p in pairs])
                rms_db = np.array([db(x) for x in rms])
                pk_db = np.array([db(x) for x in pk])
                peak_hold = np.maximum(pk_db, peak_hold - 0.6)      # ~12 dB/s fall
                e = rms[:2] ** 2
                share = (e / e.sum()).tolist() if e.sum() > 1e-10 else [0.0, 0.0]
                with midi_lock:
                    midi = {"count": midi_count, "recent": list(midi_log[-8:])}
                now = time.time()
                audio = ana.update(s[:, 4:6].mean(axis=1).astype(np.float32), float(rms_db[2]), int(now * 1000))
                # Master pair as packed 24-bit little-endian: the low three bytes of each int32.
                rec.feed(si[:, 4:6].astype("<i4").view(np.uint8).reshape(-1, 4)[:, :3].tobytes(), float(rms_db[2]), now)
                names = ["ch1", "ch2", "master"]
                msg = {"t": "mixer", "ts": int(time.time() * 1000), "connected": True, "model": "DJM-450",
                       "channels": {n: {"rms_db": round(float(rms_db[i]), 1), "peak_db": round(float(pk_db[i]), 1),
                                        "peak_hold_db": round(float(peak_hold[i]), 1),
                                        "active": bool(rms_db[i] > SILENCE_DB)} for i, n in enumerate(names)},
                       "share": {"ch1": round(share[0], 3), "ch2": round(share[1], 3)},
                       "midi": midi, "audio": audio, "rec": rec.state(),
                       "stereo": st.update(pairs, [bool(x > SILENCE_DB) for x in rms_db])}
                data = json.dumps(msg).encode()
                for tgt in TARGETS:
                    sock.sendto(data, tgt)
        finally:
            for p in (cap, play):
                p.kill()
            if rec.on:
                rec.close("capture stopped")
        log("capture stopped, retrying")
        time.sleep(2)


if __name__ == "__main__":
    run()
