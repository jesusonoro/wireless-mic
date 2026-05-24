# Wireless Microphone

Turn your Android phone into a low-latency wireless microphone. Streams 16kHz mono PCM audio over UDP to a Python desktop receiver. Target latency: **~60ms** on local Wi-Fi.

## Architecture

```
Android Phone (Flutter + Kotlin)
  └── AudioRecord → UDP packets → Wi-Fi LAN → Python receiver → speakers
```

- **Transport**: Raw UDP, 339-byte packets at 50 pps (17 KB/s)
- **Audio**: 16kHz mono PCM-16LE, 10ms chunks
- **Latency budget**: ~10ms capture + ~5ms network + ~30ms jitter buffer + ~10ms playback = ~55ms

## Quick Start

### 1. Desktop Receiver (Mac / Windows)

```bash
cd receiver
pip install -r requirements.txt
python receiver.py
```

Note the **IP address** shown in the receiver window.

### 2. Android App

Download `wireless-mic-debug.apk` from [GitHub Actions](../../actions) → latest workflow run → Artifacts.

Install it (enable *Install from unknown sources* in Android Settings → Apps).

Open the app, enter the receiver's IP address, tap **Start Streaming**.

### 3. Same Wi-Fi

Both devices must be on the same Wi-Fi network. Firewall must allow UDP port **7355** inbound on the desktop.

## Building the APK

No local Android SDK required. Every push to `main` builds the APK via GitHub Actions.

```bash
git push origin main
# → .github/workflows/build-android.yml runs
# → Download artifact: wireless-mic-debug.apk
```

## Building a Standalone Receiver Executable

```bash
# macOS → dist/receiver.app
cd receiver && bash build_macos.sh

# Windows → dist/receiver.exe
cd receiver && build_windows.bat
```

## Port / Firewall

The receiver listens on UDP port **7355** by default. Change it in both the Android app and the receiver UI if needed.

**macOS**: System Settings → Network → Firewall → Allow incoming connections for Python  
**Windows**: Windows Defender Firewall → Allow an app → Python

## Latency Tuning

In `receiver.py`, change `JITTER_BUFFER_MS`:
- `10` — minimum latency, occasional glitches on busy networks  
- `30` — default, good balance  
- `60` — smooth on congested networks  

## Project Structure

```
wireless-mic/
├── sender/          Flutter Android app (mic capture + UDP send)
├── receiver/        Python desktop app  (UDP receive + audio playback)
└── .github/         GitHub Actions APK build pipeline
```

## Phases

| Phase | Status |
|---|---|
| Architecture | ✅ |
| Android mic capture | ✅ |
| UDP streaming | ✅ |
| Python receiver | ✅ |
| GitHub Actions pipeline | ✅ |
| Opus compression (optional) | Roadmap |
| Background service | Roadmap |
