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

        # Incoming-audio level for the VU meter. Computed here from the raw PCM
        # we receive (the wire carries no level field). The network thread folds
        # each packet's peak into _level_accum; the UI drains it once per frame
        # via take_level() so no transient peak is missed between repaints.
        self._level_accum = 0.0
        self._level_lock  = threading.Lock()

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

            # Fold this packet's peak amplitude (0..1) into the meter accumulator.
            if pcm.size:
                peak = float(np.abs(pcm).max()) / 32768.0
                with self._level_lock:
                    if peak > self._level_accum:
                        self._level_accum = peak

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
        with self._level_lock:
            self._level_accum = 0.0

    def take_level(self) -> float:
        """Return the peak incoming amplitude (0..1) since the last call, then
        reset. Drained once per UI frame so brief peaks between repaints survive."""
        with self._level_lock:
            v = self._level_accum
            self._level_accum = 0.0
        return v

    def set_volume(self, v: float) -> None:
        self._volume = max(0.0, min(2.0, v))

    def set_jitter(self, ms: int) -> None:
        self.jitter.set_target_ms(ms)

    @property
    def connected(self) -> bool:
        return self.running and (time.time() - self.last_pkt_ts) < 2.0 and self.last_pkt_ts > 0


# ── Theme ────────────────────────────────────────────────────────────────────

class Theme:
    """Single source of truth for the dark UI palette."""
    BG       = "#0e1018"   # window background
    CARD     = "#171a26"   # raised card
    CARD_HI  = "#1f2333"   # card hover / inset
    STROKE   = "#272c3d"   # hairline border
    FG       = "#e6e9f2"   # primary text
    MUTED    = "#7c8499"   # secondary text
    FAINT    = "#4a5167"   # tertiary / disabled

    GREEN    = "#3ddc84"
    AMBER    = "#fbbf24"
    RED      = "#f87171"
    BLUE     = "#5b8cff"

    # Pre-darkened "off" segment colors (Tkinter Canvas has no alpha).
    GREEN_DIM = "#16301f"
    AMBER_DIM = "#322713"
    RED_DIM   = "#321b1b"


# ── VU meter ─────────────────────────────────────────────────────────────────

class VUMeter(tk.Canvas):
    """A 28-segment green/amber/red VU meter with fast-attack / slow-release
    smoothing and a peak-hold dot. Visual twin of the sender's `_MicLevel`.

    It pulls the level itself, once per animation frame, from `level_source`
    (a 0..1 callable) and animates at ~30 fps independent of the metric tick.
    """

    SEGMENTS  = 28
    FPS_MS    = 33          # ~30 fps
    GAP       = 3           # px between segments

    def __init__(self, parent, level_source, **kw):
        super().__init__(parent, highlightthickness=0, bd=0,
                         bg=Theme.CARD, **kw)
        self._level_source = level_source
        self._smooth = 0.0
        self._peak   = 0.0
        self._segs   = []          # canvas rect ids, left→right
        self._dot    = None
        self.bind("<Configure>", lambda _e: self._layout())
        self._animate()

    # Segment color by position (matches sender zones).
    @staticmethod
    def _zone(frac: float, lit: bool) -> str:
        if frac < 0.60:
            return Theme.GREEN if lit else Theme.GREEN_DIM
        if frac < 0.85:
            return Theme.AMBER if lit else Theme.AMBER_DIM
        return Theme.RED if lit else Theme.RED_DIM

    def _layout(self):
        """(Re)build the segment rectangles to fill the current width."""
        self.delete("all")
        self._segs = []
        w = self.winfo_width()
        h = self.winfo_height()
        if w <= 1 or h <= 1:
            return
        n = self.SEGMENTS
        seg_w = (w - self.GAP * (n - 1)) / n
        for i in range(n):
            x0 = i * (seg_w + self.GAP)
            rect = self.create_rectangle(
                x0, 0, x0 + seg_w, h, width=0, fill=Theme.GREEN_DIM,
            )
            self._segs.append(rect)
        self._dot = self.create_rectangle(0, 0, 0, 0, width=0, fill="")
        self._paint()

    def _animate(self):
        level = 0.0
        try:
            level = float(self._level_source() or 0.0)
        except Exception:
            level = 0.0
        # Perceptual shaping + fast-attack / slow-release (sender's constants).
        shaped = max(0.0, min(1.0, level)) ** 0.5
        self._smooth = shaped if shaped > self._smooth else self._smooth * 0.72 + shaped * 0.28
        self._peak   = shaped if shaped > self._peak   else self._peak * 0.90
        self._paint()
        self.after(self.FPS_MS, self._animate)

    def _paint(self):
        if not self._segs:
            return
        n = self.SEGMENTS
        active  = round(self._smooth * n)
        peak_i  = max(0, min(n - 1, round(self._peak * (n - 1))))
        for i, rect in enumerate(self._segs):
            frac = i / (n - 1)
            lit  = i < active
            self.itemconfigure(rect, fill=self._zone(frac, lit))
        # Peak-hold dot: light the peak segment fully even when above the bar.
        if self._peak > 0.015 and self._dot is not None:
            x0, y0, x1, y1 = self.coords(self._segs[peak_i])
            frac = peak_i / (n - 1)
            self.coords(self._dot, x0, y0, x1, y1)
            self.itemconfigure(self._dot, fill=self._zone(frac, True))


# ── UI ─────────────────────────────────────────────────────────────────────────

class App:
    def __init__(self):
        self.receiver = Receiver()
        self.root = tk.Tk()
        self.root.title("EVERMIC Receiver")
        self.root.geometry("440x600")
        self.root.minsize(380, 560)
        self.root.configure(bg=Theme.BG)
        self._build()
        self._tick()
        self.root.after(200, self._toggle)   # auto-start listening — zero-click

    # ── Reusable card container ────────────────────────────────────────────────

    def _card(self, parent, **pack_kw):
        outer = tk.Frame(parent, bg=Theme.STROKE)        # 1px hairline border
        outer.pack(fill="x", padx=20, pady=8, **pack_kw)
        inner = tk.Frame(outer, bg=Theme.CARD)
        inner.pack(fill="both", expand=True, padx=1, pady=1)
        return inner

    # ── Layout ────────────────────────────────────────────────────────────────

    def _build(self):
        T = Theme
        self._title_f = tkfont.Font(family="Helvetica Neue", size=20, weight="bold")
        self._lbl_f   = tkfont.Font(family="Helvetica Neue", size=10)
        self._val_f   = tkfont.Font(family="Menlo",          size=13, weight="bold")
        self._cap_f   = tkfont.Font(family="Helvetica Neue", size=9)
        self._meta_f  = tkfont.Font(family="Menlo",          size=10)

        # ── Header: brand + connection pill ─────────────────────────────────────
        header = tk.Frame(self.root, bg=T.BG)
        header.pack(fill="x", padx=20, pady=(18, 4))
        tk.Label(header, text="EVERMIC", font=self._title_f,
                 bg=T.BG, fg=T.FG).pack(side="left")
        tk.Label(header, text="  RECEIVER", font=self._cap_f,
                 bg=T.BG, fg=T.MUTED).pack(side="left", pady=(8, 0))

        pill = tk.Frame(header, bg=T.CARD)
        pill.pack(side="right", pady=(4, 0))
        self._dot = tk.Label(pill, text="●", font=("Helvetica", 12),
                             bg=T.CARD, fg=T.FAINT)
        self._dot.pack(side="left", padx=(10, 5), pady=4)
        self._status_lbl = tk.Label(pill, text="Idle", font=self._meta_f,
                                    bg=T.CARD, fg=T.FG)
        self._status_lbl.pack(side="left", padx=(0, 12), pady=4)

        # ── VU meter card (the centerpiece) ─────────────────────────────────────
        meter_card = self._card(self.root)
        head = tk.Frame(meter_card, bg=T.CARD)
        head.pack(fill="x", padx=16, pady=(12, 2))
        tk.Label(head, text="≈  INCOMING AUDIO", font=self._lbl_f,
                 bg=T.CARD, fg=T.MUTED).pack(side="left")
        self._db_lbl = tk.Label(head, text="—", font=self._meta_f,
                                bg=T.CARD, fg=T.FAINT)
        self._db_lbl.pack(side="right")

        self._meter = VUMeter(meter_card, self.receiver.take_level, height=44)
        self._meter.pack(fill="x", padx=16, pady=(6, 6))

        self._meter_hint = tk.Label(meter_card, text="waiting for audio…",
                                    font=self._cap_f, bg=T.CARD, fg=T.FAINT)
        self._meter_hint.pack(anchor="w", padx=16, pady=(0, 12))

        # ── Metrics card (3-up grid) ────────────────────────────────────────────
        metrics_card = self._card(self.root)
        grid = tk.Frame(metrics_card, bg=T.CARD)
        grid.pack(fill="x", padx=8, pady=12)
        grid.columnconfigure((0, 1, 2), weight=1, uniform="m")
        self._latency_lbl = self._metric_cell(grid, 0, "LATENCY")
        self._loss_lbl    = self._metric_cell(grid, 1, "PKT LOSS")
        self._buffer_lbl  = self._metric_cell(grid, 2, "BUFFER")

        # ── Controls card ───────────────────────────────────────────────────────
        ctrl = self._card(self.root)
        inner = tk.Frame(ctrl, bg=T.CARD)
        inner.pack(fill="x", padx=16, pady=12)

        # Port
        row1 = tk.Frame(inner, bg=T.CARD)
        row1.pack(fill="x", pady=(0, 8))
        tk.Label(row1, text="PORT", font=self._cap_f, bg=T.CARD, fg=T.MUTED,
                 width=8, anchor="w").pack(side="left")
        self._port_var = tk.StringVar(value=str(DEFAULT_PORT))
        tk.Entry(row1, textvariable=self._port_var, width=8, font=self._meta_f,
                 bg=T.CARD_HI, fg=T.FG, insertbackground=T.FG,
                 relief="flat", justify="center").pack(side="left", padx=4, ipady=3)

        # Volume
        row2 = tk.Frame(inner, bg=T.CARD)
        row2.pack(fill="x", pady=(0, 4))
        tk.Label(row2, text="VOLUME", font=self._cap_f, bg=T.CARD, fg=T.MUTED,
                 width=8, anchor="w").pack(side="left")
        self._vol_var = tk.DoubleVar(value=1.0)
        self._vol_lbl = tk.Label(row2, text="1.0×", font=self._meta_f,
                                 bg=T.CARD, fg=T.FG, width=5, anchor="e")
        self._vol_lbl.pack(side="right")
        tk.Scale(row2, variable=self._vol_var, from_=0.0, to=2.0,
                 resolution=0.05, orient="horizontal", showvalue=False,
                 bg=T.CARD, fg=T.FG, highlightthickness=0, troughcolor=T.CARD_HI,
                 activebackground=T.GREEN, sliderrelief="flat", bd=0, width=12,
                 command=self._on_volume).pack(side="left", fill="x", expand=True, padx=8)

        # Jitter buffer
        row3 = tk.Frame(inner, bg=T.CARD)
        row3.pack(fill="x")
        tk.Label(row3, text="BUFFER", font=self._cap_f, bg=T.CARD, fg=T.MUTED,
                 width=8, anchor="w").pack(side="left")
        self._jitter_var = tk.IntVar(value=JITTER_MS)
        self._jitter_lbl = tk.Label(row3, text=f"{JITTER_MS} ms", font=self._meta_f,
                                    bg=T.CARD, fg=T.FG, width=6, anchor="e")
        self._jitter_lbl.pack(side="right")
        tk.Scale(row3, variable=self._jitter_var, from_=10, to=120,
                 resolution=10, orient="horizontal", showvalue=False,
                 bg=T.CARD, fg=T.FG, highlightthickness=0, troughcolor=T.CARD_HI,
                 activebackground=T.BLUE, sliderrelief="flat", bd=0, width=12,
                 command=self._on_jitter).pack(side="left", fill="x", expand=True, padx=8)

        # ── Start/Stop button ─────────────────────────────────────────────────
        self._btn_text = tk.StringVar(value="Start Listening")
        self._btn = tk.Button(self.root, textvariable=self._btn_text,
                              command=self._toggle, bg=T.GREEN, fg="#08130c",
                              activebackground=T.GREEN, activeforeground="#08130c",
                              font=("Helvetica Neue", 13, "bold"),
                              relief="flat", bd=0, padx=20, pady=11, cursor="hand2")
        self._btn.pack(fill="x", padx=20, pady=(8, 6))

        # ── Local IP hint ──────────────────────────────────────────────────────
        ip = local_ip()
        host = socket.gethostname().split('.')[0]
        tk.Label(self.root,
                 text=f"Broadcasting as {host} · {ip}\nthe phone finds this automatically",
                 font=self._cap_f, bg=T.BG, fg=T.FAINT, justify="center"
                 ).pack(pady=(2, 14))

    def _metric_cell(self, parent, col: int, label: str) -> tk.Label:
        cell = tk.Frame(parent, bg=Theme.CARD)
        cell.grid(row=0, column=col, sticky="nsew", padx=8)
        tk.Label(cell, text=label, font=self._cap_f,
                 bg=Theme.CARD, fg=Theme.MUTED).pack()
        val = tk.Label(cell, text="—", font=self._val_f,
                       bg=Theme.CARD, fg=Theme.FAINT)
        val.pack(pady=(3, 0))
        return val

    # ── Control callbacks ──────────────────────────────────────────────────────

    def _on_volume(self, v):
        f = float(v)
        self.receiver.set_volume(f)
        self._vol_lbl.config(text=f"{f:g}×")

    def _on_jitter(self, v):
        ms = int(float(v))
        self.receiver.set_jitter(ms)
        self._jitter_lbl.config(text=f"{ms} ms")

    # ── Toggle start/stop ─────────────────────────────────────────────────────

    def _toggle(self):
        if not self.receiver.running:
            try:
                port = int(self._port_var.get())
            except ValueError:
                port = DEFAULT_PORT
            self.receiver.start(port)
            self._btn_text.set("Stop")
            self._btn.config(bg=Theme.RED, fg="#1a0a0a", activebackground=Theme.RED)
            self._status_lbl.config(text=f"Listening :{port}")
        else:
            self.receiver.stop()
            self._btn_text.set("Start Listening")
            self._btn.config(bg=Theme.GREEN, fg="#08130c", activebackground=Theme.GREEN)
            self._status_lbl.config(text="Idle")
            self._dot.config(fg=Theme.FAINT)

    # ── Periodic UI refresh ───────────────────────────────────────────────────

    def _tick(self):
        T = Theme
        r = self.receiver
        if r.running:
            connected = r.connected
            self._dot.config(fg=T.GREEN if connected else T.AMBER)
            self._status_lbl.config(text="Connected ✓" if connected else "Waiting…")
            self._meter_hint.config(
                text="live" if connected else "waiting for audio…",
                fg=T.GREEN if connected else T.FAINT,
            )

            # dB readout from the meter's smoothed level.
            sm = self._meter._smooth
            self._db_lbl.config(
                text=(f"{20 * np.log10(max(sm, 1e-4)):.0f} dB" if sm > 0.015 else "—"),
                fg=T.FG if sm > 0.015 else T.FAINT,
            )

            lat = r.latency_ms
            lat_color = T.GREEN if lat < 80 else (T.AMBER if lat < 150 else T.RED)
            self._latency_lbl.config(text=f"{lat} ms", fg=lat_color)

            total, dropped = r.received, r.dropped
            loss_pct = (dropped / max(total + dropped, 1)) * 100
            self._loss_lbl.config(
                text=f"{loss_pct:.1f}%",
                fg=T.GREEN if loss_pct < 1 else (T.AMBER if loss_pct < 5 else T.RED),
            )
            self._buffer_lbl.config(text=f"{r.jitter.buffered_ms:.0f} ms", fg=T.FG)

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
