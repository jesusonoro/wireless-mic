# EVERMIC — Wireless Microphone

Turns an Android phone into a wireless microphone for your computer. Speak into the
phone, the audio comes out the computer's speakers. Target latency: **~60ms**.

**Zero config:** both ends find each other automatically on the same Wi-Fi — no IP
addresses to type. Just open the app on the phone and the receiver on the desktop.

## What it is

Two components talking over UDP on the same LAN:

- **`sender/`** — Flutter Android app. Captures mic via `AudioRecord` (Kotlin plugin), encodes as PCM-16LE, sends UDP packets. Auto-discovers the receiver, shows a live mic input-level meter.
- **`receiver/`** — Python desktop app (Mac/Windows). Receives UDP packets, buffers with a jitter buffer, plays through system speakers via `sounddevice`. Broadcasts a discovery beacon so the phone finds it. Has a Tkinter GUI (auto-starts listening) and a `--headless` CLI mode.

## Repo structure

```
evermic/
├── sender/                         Flutter Android app
│   ├── lib/
│   │   ├── main.dart               App entry — MaterialApp shell
│   │   ├── ui/sender_screen.dart   UI: auto-discovery status, VU meter, start/stop, manual fallback
│   │   ├── discovery/discovery_service.dart  Listens for receiver beacons → auto-connect
│   │   └── audio/audio_service.dart  Dart ↔ Kotlin bridge (MethodChannel + EventChannel)
│   └── android/app/src/main/kotlin/com/wirelessmic/sender/
│       ├── MainActivity.kt         Registers plugin; creates "evermic_mic" notification channel
│       ├── AudioStreamPlugin.kt    MethodChannel + EventChannel bridge; holds the Wi-Fi multicast lock
│       └── AudioForegroundService.kt  Owns AudioRecord + UDP loop; computes mic level; persistent notification
├── receiver/
│   ├── receiver.py                 Single-file receiver: Receiver + JitterBuffer + discovery beacon + Tkinter App
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

## Auto-discovery protocol

So neither side needs an IP typed in, the receiver advertises itself and the sender
listens. All over UDP broadcast on the **discovery port `7356`** (separate from the
audio port `7355`).

- **Receiver** broadcasts a beacon to `255.255.255.255:7356` once a second while it's
  listening (see `_broadcast_loop` in `receiver.py`).
- **Sender** binds `0.0.0.0:7356`, parses beacons, takes the **source IP** as the
  receiver host, and auto-connects to the first one it hears
  (`discovery_service.dart`). A manual IP entry remains as a fallback for
  AP-isolated networks.

Beacon layout:

```
Offset  Size  Field
0       8     magic "EVERMIC1"
8       2     audio port (uint16 big-endian)
10      1     hostname length N (uint8)
11      N     hostname (UTF-8)
```

> **Android multicast lock is mandatory.** Many Wi-Fi drivers (Xiaomi/HyperOS
> included) drop inbound broadcast/multicast unless a `WifiManager.MulticastLock` is
> held. `AudioStreamPlugin` acquires one (`acquireMulticastLock`) while discovery runs;
> without it the sender never hears the beacon. Requires `CHANGE_WIFI_MULTICAST_STATE`.

## Audio parameters (fixed)

| Parameter   | Value      |
|-------------|------------|
| Sample rate | 16,000 Hz  |
| Channels    | 1 (mono)   |
| Bit depth   | 16-bit LE  |
| Chunk size  | 10ms       |
| Audio UDP port | 7355    |
| Discovery UDP port | 7356 |

## Key classes

### `receiver.py` — `JitterBuffer` (line 43)

Thread-safe ring buffer of `int16` samples. `push(pcm)` from network thread, `pull(n)` from sounddevice audio callback. Zero-pads on underrun. Target depth controlled by `set_target_ms(ms)`.

### `receiver.py` — `Receiver` (line 88)

Owns the UDP socket, sounddevice output stream, and receive thread. Tracks `received`, `dropped`, `latency_ms` counters. `connected` property returns `True` if a packet arrived within the last 2 seconds.

### `receiver.py` — `App` (line 191)

Tkinter UI. Polls `Receiver` state every 200ms via `root.after(200, self._tick)`. Exposes port, volume (0–2×), and jitter buffer (10–120ms) controls.

### `sender/lib/audio/audio_service.dart` (line 1)

Dart wrapper around two platform channels:
- `MethodChannel('com.wirelessmic/audio')` — `start({host, port})`, `stop()`, `acquireMulticastLock`, `releaseMulticastLock`
- `EventChannel('com.wirelessmic/audio_events')` — emits `{sequenceNumber, timestampMs, level}` maps (~20/s; `level` is peak mic amplitude 0..1 for the VU meter)

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
python receiver.py        # auto-starts listening + broadcasting its beacon
```

**Sender (Android):**
1. Download `wireless-mic-debug.apk` from GitHub Actions artifacts, or build locally.
2. Install (enable *Install from unknown sources*).
3. Open **EVERMIC**, grant the microphone permission. It auto-finds the receiver and
   starts streaming — speak into the phone, audio comes out the desktop speakers.

Both devices must be on the same Wi-Fi. Allow UDP ports **7355** (audio) and **7356**
(discovery) inbound on the desktop. If the phone stays on "Searching…" (some routers
block client-to-client broadcast), tap **Connect manually** and enter the desktop's IP.

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

## Gotchas (hard-won)

- **Never `connect()` the sender's `DatagramSocket`.** A *connected* UDP socket throws
  on `send()` the moment the route blips or an async ICMP error arrives — which here
  tore down the whole stream on the first packet, while the UI still said "Connected".
  Send fire-and-forget with an explicit destination instead. (`AudioForegroundService.startAudio`)
- **Don't swallow exceptions silently in the stream loop.** The original `catch { break }`
  hid the send failure completely; the symptom was "0 packets sent, no error anywhere."
  Every failure path now logs under tag `evermic` — `adb logcat | grep evermic`.
- **Discovery receive needs a multicast lock on Android** (see the discovery section).
- **Xiaomi/HyperOS blocks `adb install`** with `INSTALL_FAILED_USER_RESTRICTED` unless
  Developer options → *Install via USB* is enabled (needs a Mi account). Sideload via
  browser/file manager instead, or enable that toggle. `adb uninstall` is not blocked.
- **CI debug builds are signed with a fresh key each run**, so a new APK won't install
  *over* an old one (`INSTALL_FAILED_UPDATE_INCOMPATIBLE` / signature mismatch).
  Uninstall the previous build first.
- **The receiver ignores packets shorter than the 19-byte header**, so a raw `nc` probe
  won't register as "received" — test reachability with a dedicated listener instead.

## Debugging the phone without a cable

USB not an option? Use **wireless ADB** (both devices on the same Wi-Fi):

```bash
# On the phone: Developer options → Wireless debugging → Pair device with pairing code
adb pair   <phone-ip>:<PAIRING-port>   <6-digit-code>   # pairing port (from the dialog)
adb connect <phone-ip>:<CONNECT-port>                    # connect port (main WiFi-debug screen)
adb mdns services        # reveals both ports if you can't read them off the screen
adb -s <phone-ip>:<port> logcat | grep -iE "evermic|AudioRecord|AudioFlinger|send failed"
```

Pairing and connect ports differ — that trips everyone up. `adb mdns services` lists
`_adb-tls-pairing` and `_adb-tls-connect` so you can grab the right one.

## Roadmap

| Feature | Status |
|---------|--------|
| Android mic capture + UDP send | done |
| Python receiver + jitter buffer | done |
| Tkinter GUI with live metrics | done |
| GitHub Actions CI build | done |
| Android foreground service (background streaming) | done |
| Zero-config LAN auto-discovery | done |
| Mic input-level VU meter | done |
| Opus compression | roadmap |
