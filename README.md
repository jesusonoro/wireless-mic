# evermic — Wireless Microphone

Streams Android microphone audio to a desktop over local Wi-Fi. Target latency: **~60ms**.

## What it is

Two components talking over UDP on the same LAN:

- **`sender/`** — Flutter Android app. Captures mic via `AudioRecord` (Kotlin plugin), encodes as PCM-16LE, sends UDP packets.
- **`receiver/`** — Python desktop app (Mac/Windows). Receives UDP packets, buffers with a jitter buffer, plays through system speakers via `sounddevice`. Has a Tkinter GUI and a `--headless` CLI mode.

## Repo structure

```
evermic/
├── sender/                         Flutter Android app
│   ├── lib/
│   │   ├── main.dart               App entry — MaterialApp shell
│   │   ├── ui/sender_screen.dart   UI: IP/port inputs, start/stop button, metrics
│   │   └── audio/audio_service.dart  Dart ↔ Kotlin bridge (MethodChannel + EventChannel)
│   └── android/app/src/main/kotlin/com/wirelessmic/sender/
│       ├── MainActivity.kt         Registers plugin; creates "evermic_mic" notification channel
│       ├── AudioStreamPlugin.kt    MethodChannel + EventChannel bridge → starts/binds the service
│       └── AudioForegroundService.kt  Owns AudioRecord + UDP loop; shows persistent notification
├── receiver/
│   ├── receiver.py                 Single-file receiver: Receiver class + JitterBuffer + Tkinter App
│   └── requirements.txt            sounddevice, numpy
├── .github/workflows/
│   └── build-android.yml           CI: builds debug APK on push to main, uploads as artifact
└── wireless-mic-debug.apk          Pre-built debug APK (committed for convenience)
```

## UDP packet format

Every packet has a 19-byte header followed by raw PCM payload:

```
Offset  Size  Type              Field
0       4     uint32 big-endian sequence number (monotonically increasing)
4       8     int64  big-endian sender timestamp (ms since epoch)
12      1     uint8             flags (reserved, always 0)
13      2     uint16 big-endian sample rate (always 16000)
15      1     uint8             channels (always 1)
16      1     uint8             codec (0 = PCM16LE)
17      2     uint16 big-endian payload length in bytes
19      plen  bytes             PCM-16LE audio payload
```

Struct format string: `">IqBHBBH"` (matches `HEADER_FMT` / `HEADER_SIZE = 19` in `receiver.py:32-33`).

**Packet cadence**: 10ms audio chunks → 50 packets/s → ~17 KB/s at 16kHz mono PCM16.

## Audio parameters (fixed)

| Parameter   | Value      |
|-------------|------------|
| Sample rate | 16,000 Hz  |
| Channels    | 1 (mono)   |
| Bit depth   | 16-bit LE  |
| Chunk size  | 10ms       |
| UDP port    | 7355       |

## Key classes

### `receiver.py` — `JitterBuffer` (line 43)

Thread-safe ring buffer of `int16` samples. `push(pcm)` from network thread, `pull(n)` from sounddevice audio callback. Zero-pads on underrun. Target depth controlled by `set_target_ms(ms)`.

### `receiver.py` — `Receiver` (line 88)

Owns the UDP socket, sounddevice output stream, and receive thread. Tracks `received`, `dropped`, `latency_ms` counters. `connected` property returns `True` if a packet arrived within the last 2 seconds.

### `receiver.py` — `App` (line 191)

Tkinter UI. Polls `Receiver` state every 200ms via `root.after(200, self._tick)`. Exposes port, volume (0–2×), and jitter buffer (10–120ms) controls.

### `sender/lib/audio/audio_service.dart` (line 1)

Dart wrapper around two platform channels:
- `MethodChannel('com.wirelessmic/audio')` — `start({host, port})`, `stop()`
- `EventChannel('com.wirelessmic/audio_events')` — emits `{sequenceNumber, timestampMs}` maps

The Kotlin plugin (`AudioStreamPlugin`) is registered in `MainActivity.kt`.

### `AudioForegroundService.kt`

Android `Service` that owns the entire audio/UDP loop so streaming survives screen lock, backgrounding, and app switches.

- Started with `startForegroundService()` by `AudioStreamPlugin` when Dart calls `start`.
- Calls `startForeground()` immediately in `onStartCommand`, showing a persistent notification ("evermic — Streaming…") with a **Stop** action.
- The Stop action delivers `ACTION_STOP` back to the service, which shuts down cleanly and dismisses the notification.
- `AudioStreamPlugin` binds to the service via `ServiceConnection` to wire up the `metricsListener` callback, which forwards `{sequenceNumber, timestampMs}` events to the Dart `EventChannel`.
- Dart `AudioService.startStreaming()` / `stopStreaming()` API is unchanged.

## Quick start

**Receiver (desktop):**
```bash
cd receiver
pip install -r requirements.txt
python receiver.py
# note the IP shown in the window
```

**Sender (Android):**
1. Download `wireless-mic-debug.apk` from GitHub Actions artifacts, or build locally.
2. Install (enable *Install from unknown sources*).
3. Enter the receiver's IP → tap **Start Streaming**.

Both devices must be on the same Wi-Fi. Allow UDP port 7355 inbound on the desktop.

**Headless receiver (no GUI):**
```bash
python receiver.py --headless --port 7355
```

## Building

**Android APK — CI (primary path):** Push to `main` or open a PR → GitHub Actions (`.github/workflows/build-android.yml`) runs `flutter build apk --debug` and uploads `wireless-mic-debug.apk` as a 30-day artifact. No local Flutter or Android SDK required. Use `workflow_dispatch` on the Actions tab to trigger a manual build without a push.

**Android APK — local (optional):** Only needed if you have Flutter installed locally.
```bash
cd sender
flutter pub get
flutter build apk --debug
# output: build/app/outputs/flutter-apk/app-debug.apk
```

**Standalone receiver binary:**
```bash
# macOS
cd receiver && bash build_macos.sh     # → dist/receiver.app

# Windows
cd receiver && build_windows.bat       # → dist/receiver.exe
```

## Latency budget

| Stage           | Typical |
|-----------------|---------|
| Mic capture     | ~10ms   |
| Network (LAN)   | ~5ms    |
| Jitter buffer   | ~30ms   |
| Playback block  | ~10ms   |
| **Total**       | **~55ms** |

Tune `JITTER_MS` in `receiver.py:39` (default `30`). Lower = less latency, more risk of glitches. 10ms is minimum; 60ms is safe on congested networks.

## Extension points

| Goal | Where to change |
|------|----------------|
| Add Opus compression | Sender: Kotlin plugin; Receiver: decode before `np.frombuffer`; set `codec` byte to non-zero |
| Change sample rate | `SAMPLE_RATE` in `receiver.py:36` + matching `AudioRecord` config in Kotlin plugin |
| ~~Run as Android background service~~ | done — `AudioForegroundService` owns the audio loop; streaming survives screen lock and backgrounding |
| Release APK signing | Uncomment `build-release` job in `.github/workflows/build-android.yml`, add `KEYSTORE_BASE64` / `KEY_ALIAS` / `KEY_PASSWORD` / `STORE_PASSWORD` secrets |
| Change UDP port | `DEFAULT_PORT` in `receiver.py:36`; default `'7355'` in `sender_screen.dart:17` |

## Firewall setup

**macOS:** System Settings → Network → Firewall → Allow incoming connections for Python

**Windows:** Windows Defender Firewall → Allow an app → Python

## Roadmap

| Feature | Status |
|---------|--------|
| Android mic capture + UDP send | done |
| Python receiver + jitter buffer | done |
| Tkinter GUI with live metrics | done |
| GitHub Actions CI build | done |
| Android foreground service (background streaming) | done |
| Opus compression | roadmap |
