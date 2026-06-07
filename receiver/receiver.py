#!/usr/bin/env python3
"""
Wireless Microphone Receiver
Listens for UDP audio packets from the Android sender app and plays them
through the system speakers via PortAudio.

Packet format (19-byte header + PCM payload):
  [0:4]   sequence number (uint32 big-endian)
  [4:12]  sender timestamp ms (int64 big-endian)
  [12]    flags (reserved)
  [13:15] sample rate (uint16 big-endian)
  [15]    channels (uint8)
  [16]    codec (uint8) — 0 = PCM16LE
  [17:19] payload length (uint16 big-endian)
  [19:]   audio payload
"""

import socket
import struct
import time
import threading
import collections
import sys

import numpy as np
import sounddevice as sd
import tkinter as tk
from tkinter import ttk, font as tkfont

# ── Constants ──────────────────────────────────────────────────────────────────

HEADER_FMT = ">IqBHBBH"   # seq(4) ts(8) flags(1) sr(2) ch(1) codec(1) plen(2)
HEADER_SIZE = struct.calcsize(HEADER_FMT)  # == 19

DEFAULT_PORT = 7355
SAMPLE_RATE  = 16_000
CHANNELS     = 1
DTYPE        = np.int16
JITTER_MS    = 30          # default jitter buffer depth

# ── Auto-discovery ──────────────────────────────────────────────────────────────
# The receiver announces itself on the LAN so the sender finds it with zero config.
# Beacon: b"EVERMIC1" (8) + audio_port uint16 BE (2) + name_len uint8 (1) + name.
DISCOVERY_PORT = 7356
DISCOVERY_MAGIC = b"EVERMIC1"


def local_ip() -> str:
    """Best-effort LAN IP (the address the sender will actually reach)."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))      # no packets sent; just picks the route
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()

# ── Jitter buffer ──────────────────────────────────────────────────────────────

class JitterBuffer:
    """Thread-safe ring buffer of int16 samples."""

    def __init__(self, target_ms: int, sample_rate: int = SAMPLE_RATE):
        self._target_samples = int(target_ms * sample_rate / 1000)
        self._buf: collections.deque[np.ndarray] = collections.deque()
        self._total: int = 0
        self._lock = threading.Lock()

    def push(self, pcm: np.ndarray) -> None:
        with self._lock:
            self._buf.append(pcm)
            self._total += len(pcm)

    def pull(self, n: int) -> np.ndarray:
        """Return exactly n samples (zero-pad if starved)."""
        out = np.zeros(n, dtype=DTYPE)
        pos = 0
        with self._lock:
            while pos < n and self._buf:
                chunk = self._buf[0]
                need = n - pos
                if len(chunk) <= need:
                    out[pos:pos + len(chunk)] = chunk
                    pos += len(chunk)
                    self._total -= len(chunk)
                    self._buf.popleft()
                else:
                    out[pos:] = chunk[:need]
                    self._buf[0] = chunk[need:]
                    self._total -= need
                    pos = n
        return out

    @property
    def buffered_ms(self) -> float:
        with self._lock:
            return self._total * 1000 / SAMPLE_RATE

    def set_target_ms(self, ms: int) -> None:
        self._target_samples = int(ms * SAMPLE_RATE / 1000)


# ── Receiver ───────────────────────────────────────────────────────────────────

class Receiver:
    def __init__(self):
        self.jitter = JitterBuffer(JITTER_MS)
        self._sock: socket.socket | None = None
        self._stream: sd.OutputStream | None = None
        self._thread: threading.Thread | None = None
        self._disc_sock: socket.socket | None = None
        self._disc_thread: threading.Thread | None = None
        self.running = False

        # Metrics (read from UI thread)
        self.received    = 0
        self.dropped     = 0
        self.latency_ms  = 0
        self.last_pkt_ts = 0.0
        self._last_seq   = -1
        self._volume     = 1.0

    # ── Audio output callback (called from sounddevice worker thread) ──────────

    def _audio_cb(self, outdata: np.ndarray, frames: int, _time, _status):
        samples = self.jitter.pull(frames)
        # Apply volume
        if self._volume != 1.0:
            samples = (samples * self._volume).astype(DTYPE)
        outdata[:, 0] = samples

    # ── Network receive loop ───────────────────────────────────────────────────

    def _recv_loop(self):
        assert self._sock is not None
        while self.running:
            try:
                data, _ = self._sock.recvfrom(65_535)
            except OSError:
                break

            if len(data) < HEADER_SIZE:
                continue

            seq, ts_ms, _flags, _sr, _ch, _codec, plen = struct.unpack_from(
                HEADER_FMT, data, 0
            )
            payload = data[HEADER_SIZE: HEADER_SIZE + plen]
            if len(payload) < plen:
                continue

            now_ms = int(time.time() * 1000)
            self.latency_ms = now_ms - ts_ms
            self.last_pkt_ts = time.time()

            if self._last_seq >= 0:
                gap = seq - self._last_seq - 1
                if gap > 0:
                    self.dropped += gap
            self._last_seq = seq
            self.received += 1

            pcm = np.frombuffer(payload, dtype="<i2").copy()
            self.jitter.push(pcm)

    # ── Discovery beacon ───────────────────────────────────────────────────────

    def _broadcast_loop(self, audio_port: int) -> None:
        """Announce this receiver on the LAN broadcast address once a second."""
        name = socket.gethostname().split(".")[0].encode("utf-8")[:255]
        beacon = DISCOVERY_MAGIC + struct.pack(">H", audio_port) + bytes([len(name)]) + name

        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        self._disc_sock = sock
        while self.running:
            try:
                sock.sendto(beacon, ("255.255.255.255", DISCOVERY_PORT))
            except OSError:
                pass
            time.sleep(1.0)

    # ── Start / stop ───────────────────────────────────────────────────────────

    def start(self, port: int = DEFAULT_PORT) -> None:
        self._sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self._sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 131_072)
        self._sock.bind(("0.0.0.0", port))
        self._sock.settimeout(0.5)
        self.running = True

        self._stream = sd.OutputStream(
            samplerate=SAMPLE_RATE,
            channels=CHANNELS,
            dtype=DTYPE,
            blocksize=int(SAMPLE_RATE * 0.010),   # 10ms output block
            callback=self._audio_cb,
        )
        self._stream.start()

        self._thread = threading.Thread(target=self._recv_loop, daemon=True)
        self._thread.start()

        self._disc_thread = threading.Thread(
            target=self._broadcast_loop, args=(port,), daemon=True
        )
        self._disc_thread.start()

    def stop(self) -> None:
        self.running = False
        if self._sock:
            self._sock.close()
        if self._disc_sock:
            self._disc_sock.close()
        if self._stream:
            self._stream.stop()
            self._stream.close()
        if self._thread:
            self._thread.join(timeout=1.0)
        if self._disc_thread:
            self._disc_thread.join(timeout=1.5)

    def set_volume(self, v: float) -> None:
        self._volume = max(0.0, min(2.0, v))

    def set_jitter(self, ms: int) -> None:
        self.jitter.set_target_ms(ms)

    @property
    def connected(self) -> bool:
        return self.running and (time.time() - self.last_pkt_ts) < 2.0 and self.last_pkt_ts > 0


# ── UI ─────────────────────────────────────────────────────────────────────────

class App:
    BG     = "#1a1a2e"
    CARD   = "#16213e"
    ACCENT = "#0f3460"
    GREEN  = "#4ade80"
    YELLOW = "#facc15"
    RED    = "#f87171"
    FG     = "#e2e8f0"

    def __init__(self):
        self.receiver = Receiver()
        self.root = tk.Tk()
        self.root.title("EVERMIC Receiver")
        self.root.geometry("460x460")
        self.root.configure(bg=self.BG)
        self.root.resizable(False, False)
        self._build()
        self._tick()

    # ── Layout ────────────────────────────────────────────────────────────────

    def _build(self):
        pad = dict(padx=16, pady=6)

        title_f = tkfont.Font(family="Helvetica", size=15, weight="bold")
        mono_f  = tkfont.Font(family="Courier",   size=11)
        sm_f    = tkfont.Font(family="Helvetica", size=10)

        tk.Label(self.root, text="EVERMIC Receiver",
                 font=title_f, bg=self.BG, fg=self.FG).pack(pady=(16, 4))

        # ── Status indicator ──────────────────────────────────────────────────
        status_frame = tk.Frame(self.root, bg=self.CARD, relief="flat")
        status_frame.pack(fill="x", **pad)

        self._dot = tk.Label(status_frame, text="●", font=("Helvetica", 18),
                             bg=self.CARD, fg=self.RED)
        self._dot.pack(side="left", padx=(12, 6), pady=8)

        self._status_lbl = tk.Label(status_frame, text="Stopped",
                                    font=mono_f, bg=self.CARD, fg=self.FG)
        self._status_lbl.pack(side="left", pady=8)

        # ── Metrics ───────────────────────────────────────────────────────────
        metrics_frame = tk.Frame(self.root, bg=self.CARD)
        metrics_frame.pack(fill="x", **pad)

        self._latency_lbl = self._metric_row(metrics_frame, "Latency",   "—")
        self._loss_lbl    = self._metric_row(metrics_frame, "Pkt loss",  "—")
        self._buffer_lbl  = self._metric_row(metrics_frame, "Buffer",    "—")

        # ── Config row ────────────────────────────────────────────────────────
        cfg_frame = tk.Frame(self.root, bg=self.BG)
        cfg_frame.pack(fill="x", **pad)

        tk.Label(cfg_frame, text="Port:", bg=self.BG, fg=self.FG, font=sm_f).pack(side="left")
        self._port_var = tk.StringVar(value=str(DEFAULT_PORT))
        tk.Entry(cfg_frame, textvariable=self._port_var, width=7,
                 bg=self.ACCENT, fg=self.FG, insertbackground=self.FG,
                 relief="flat").pack(side="left", padx=(4, 16))

        # Volume
        tk.Label(cfg_frame, text="Volume:", bg=self.BG, fg=self.FG, font=sm_f).pack(side="left")
        self._vol_var = tk.DoubleVar(value=1.0)
        tk.Scale(cfg_frame, variable=self._vol_var, from_=0.0, to=2.0,
                 resolution=0.05, orient="horizontal", length=120,
                 bg=self.BG, fg=self.FG, highlightthickness=0, troughcolor=self.ACCENT,
                 command=lambda v: self.receiver.set_volume(float(v))).pack(side="left")

        # Jitter buffer
        jb_frame = tk.Frame(self.root, bg=self.BG)
        jb_frame.pack(fill="x", **pad)
        tk.Label(jb_frame, text="Jitter buffer (ms):", bg=self.BG, fg=self.FG, font=sm_f).pack(side="left")
        self._jitter_var = tk.IntVar(value=JITTER_MS)
        tk.Scale(jb_frame, variable=self._jitter_var, from_=10, to=120,
                 resolution=10, orient="horizontal", length=200,
                 bg=self.BG, fg=self.FG, highlightthickness=0, troughcolor=self.ACCENT,
                 command=lambda v: self.receiver.set_jitter(int(float(v)))).pack(side="left")
        self._jitter_lbl = tk.Label(jb_frame, text=f"{JITTER_MS}ms",
                                    bg=self.BG, fg=self.FG, font=sm_f, width=5)
        self._jitter_lbl.pack(side="left")

        # ── Start/Stop button ─────────────────────────────────────────────────
        self._btn_text = tk.StringVar(value="Start Listening")
        tk.Button(self.root, textvariable=self._btn_text, command=self._toggle,
                  bg=self.GREEN, fg="#111", font=("Helvetica", 12, "bold"),
                  relief="flat", padx=20, pady=10, cursor="hand2").pack(pady=(8, 4))

        # ── Local IP hint ──────────────────────────────────────────────────────
        ip = local_ip()
        tk.Label(self.root, text=f"Broadcasting as {socket.gethostname().split('.')[0]} · {ip}  — the app finds this automatically",
                 font=sm_f, bg=self.BG, fg="#94a3b8").pack(pady=(4, 12))

    def _metric_row(self, parent: tk.Frame, label: str, initial: str) -> tk.Label:
        row = tk.Frame(parent, bg=self.CARD)
        row.pack(fill="x", padx=12, pady=2)
        tk.Label(row, text=f"{label}:", bg=self.CARD, fg="#94a3b8",
                 font=("Helvetica", 10), width=10, anchor="w").pack(side="left")
        lbl = tk.Label(row, text=initial, bg=self.CARD, fg=self.FG,
                       font=("Courier", 10), anchor="w")
        lbl.pack(side="left")
        return lbl

    # ── Toggle start/stop ─────────────────────────────────────────────────────

    def _toggle(self):
        if not self.receiver.running:
            try:
                port = int(self._port_var.get())
            except ValueError:
                port = DEFAULT_PORT
            self.receiver.start(port)
            self._btn_text.set("Stop")
            self._status_lbl.config(text=f"Listening on UDP :{port} …")
        else:
            self.receiver.stop()
            self._btn_text.set("Start Listening")
            self._status_lbl.config(text="Stopped")
            self._dot.config(fg=self.RED)

    # ── Periodic UI refresh ───────────────────────────────────────────────────

    def _tick(self):
        r = self.receiver
        if r.running:
            connected = r.connected
            self._dot.config(fg=self.GREEN if connected else self.YELLOW)
            self._status_lbl.config(
                text=("Connected ✓" if connected else "Waiting for sender …")
            )
            lat = r.latency_ms
            lat_color = self.GREEN if lat < 80 else (self.YELLOW if lat < 150 else self.RED)
            self._latency_lbl.config(text=f"{lat} ms", fg=lat_color)

            total = r.received
            dropped = r.dropped
            loss_pct = (dropped / max(total + dropped, 1)) * 100
            self._loss_lbl.config(
                text=f"{dropped} dropped / {total} total  ({loss_pct:.1f}%)",
                fg=self.GREEN if loss_pct < 1 else (self.YELLOW if loss_pct < 5 else self.RED)
            )
            self._buffer_lbl.config(text=f"{r.jitter.buffered_ms:.0f} ms")
            jms = self._jitter_var.get()
            self._jitter_lbl.config(text=f"{jms}ms")

        self.root.after(200, self._tick)

    def run(self):
        self.root.protocol("WM_DELETE_WINDOW", self._on_close)
        self.root.mainloop()

    def _on_close(self):
        self.receiver.stop()
        self.root.destroy()


# ── Entry point ────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    # Quick CLI mode: python receiver.py --headless --port 7355
    if "--headless" in sys.argv:
        idx = sys.argv.index("--port") if "--port" in sys.argv else -1
        port = int(sys.argv[idx + 1]) if idx >= 0 else DEFAULT_PORT
        r = Receiver()
        r.start(port)
        print(f"EVERMIC receiver listening on UDP {local_ip()}:{port}. Ctrl-C to stop.")
        print(f"Broadcasting discovery beacon on :{DISCOVERY_PORT} — sender auto-connects.")
        try:
            while True:
                time.sleep(1)
                status = "connected" if r.connected else "waiting"
                print(f"[{status}] latency={r.latency_ms}ms  "
                      f"pkts={r.received}  dropped={r.dropped}  "
                      f"buffer={r.jitter.buffered_ms:.0f}ms")
        except KeyboardInterrupt:
            r.stop()
    else:
        App().run()
