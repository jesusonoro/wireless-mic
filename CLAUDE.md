# evermic — Claude Working Notes

## Build workflow

There is no local Flutter install. All Android builds run in CI (GitHub Actions).

**To get a debug APK:**
```
bash download_apk.sh
```
This polls CI until the build is green, then downloads the APK to `wireless-mic-debug.apk`.

**Repo:** https://github.com/jesusonoro/wireless-mic  
**Workflow:** `.github/workflows/build-android.yml`

**Installing on a Xiaomi/HyperOS device:** `adb install` is blocked
(`INSTALL_FAILED_USER_RESTRICTED`) unless Developer options → *Install via USB* is on
(needs a Mi account). Sideload via browser/file manager instead. Each CI build is signed
with a fresh debug key, so **uninstall the old app first** (`adb uninstall com.wirelessmic.sender`)
or the install fails on signature mismatch. To debug without a cable, use **wireless ADB**
(`adb pair <ip>:<pairing-port> <code>` then `adb connect <ip>:<connect-port>`; the two
ports differ — `adb mdns services` shows both). Then `adb logcat | grep evermic`.

---

## Version compatibility chain

Flutter's stable channel pins specific minimum versions of the Android toolchain. When a Flutter plugin pulls in a newer stdlib, the whole chain must be bumped together.

| Component | File | Current |
|---|---|---|
| AGP (com.android.application) | `sender/android/settings.gradle` | 8.7.0 |
| Kotlin plugin (org.jetbrains.kotlin.android) | `sender/android/settings.gradle` | 2.2.0 |
| Gradle wrapper | `sender/android/gradle/wrapper/gradle-wrapper.properties` | 8.10 |
| Flutter channel | `.github/workflows/build-android.yml` | latest stable |

**Key lesson:** `package_info_plus` 9.x pulls `kotlin-stdlib-2.2.0.jar`. The Kotlin plugin version must match the stdlib version exactly — the metadata binary format is not backwards compatible.

**Diagnosis pattern:** When you see:
```
Module was compiled with an incompatible version of Kotlin.
The binary version of its metadata is X.Y.Z, expected version is A.B.C.
```
Bump `org.jetbrains.kotlin.android` to `X.Y.Z` in `settings.gradle`.

---

## Architecture

Flutter app in `sender/` with a native Android plugin for microphone audio streaming.

Key files:
- `sender/android/app/src/main/kotlin/com/wirelessmic/sender/AudioForegroundService.kt` — background audio streaming via ForegroundService; two capture paths: **MIC** (16 kHz mono, VOICE_COMMUNICATION source, voice DSP, 10 ms chunks) and **DJ** (two AudioRecords — mic at 48 kHz mono + playback capture at 48 kHz stereo via `AudioPlaybackCaptureConfiguration` — mixed with MUSIC_GAIN 0.85 / MIC_GAIN 1.0, streamed as 48 kHz stereo LE, 5 ms chunks); computes per-chunk peak for the VU meter
- `sender/android/app/src/main/kotlin/com/wirelessmic/sender/AudioStreamPlugin.kt` — Flutter↔native bridge; `ActivityAware`; holds the Wi-Fi `MulticastLock` during discovery; exposes `startDj` which launches the system MediaProjection consent dialog
- `sender/android/app/src/main/kotlin/com/wirelessmic/sender/MainActivity.kt` — creates notification channel
- `sender/android/app/src/main/AndroidManifest.xml` — FOREGROUND_SERVICE + FOREGROUND_SERVICE_MEDIA_PROJECTION permissions; service declared with `foregroundServiceType="microphone|mediaProjection"`
- `sender/lib/discovery/discovery_service.dart` — listens for receiver beacons (UDP :7356) → auto-connect
- `sender/lib/ui/sender_screen.dart` — Mic/DJ SegmentedButton; DJ skips auto-connect (requires explicit Start to avoid an unprompted consent dialog)
- `receiver/receiver.py` — receiver + jitter buffer + discovery-beacon broadcaster; format-aware: reads per-packet sample-rate + channel count from the wire header and reconfigures OutputStream/JitterBuffer on format change (was hardcoded 16 kHz mono); decodes interleaved stereo; dark Tkinter GUI + `VUMeter`

## Gotchas (hard-won)

- **The sender's UDP socket must NOT be `connect()`-ed.** A connected `DatagramSocket`
  throws on `send()` when the route blips / an async ICMP error arrives, which killed the
  stream on packet 0 while the UI still showed "Connected." Send fire-and-forget with an
  explicit destination. *Symptom: 0 packets sent, no visible error.*
- **Never swallow exceptions in the audio loop.** All failure paths log under tag
  `evermic` now. The original silent `catch { break }` cost hours.
- **Auto-discovery needs a `MulticastLock`** or HyperOS drops the inbound broadcast beacon
  and the sender never finds the receiver. Held by `AudioStreamPlugin` while discovering.
- Discovery is UDP broadcast on **:7356** (audio is **:7355**). Beacon =
  `"EVERMIC1"` + audio-port(u16 BE) + namelen(u8) + hostname.
- **The receiver UI needs Tk 8.6+.** macOS's system `python3` (CommandLineTools,
  3.9.6) ships **Tk 8.5.9**, which renders the Tkinter window blank/garbled on
  modern macOS — the body shows nothing but the native titlebar + button. Verify
  with `python3 -c "import tkinter;print(tkinter.Tk().tk.call('info','patchlevel'))"`.
  Build/run with a python.org or Homebrew Python (`brew install python@3.12
  python-tk@3.12` → Tk 9.x). The bundled PyInstaller binaries embed whatever Tk
  the building interpreter had, so build with a modern-Tk python too.
- **PyInstaller + sounddevice:** bundle the PortAudio binary with
  `--collect-all sounddevice` (both build scripts do). Without it the frozen app
  starts then dies on `import sounddevice` (missing libportaudio).
- **DJ mode — Android 14 FGS ordering:** the service must be started with
  `foregroundServiceType` including `mediaProjection` *before* calling
  `getMediaProjection()`, and a `MediaProjection.Callback` must be registered on
  the projection object before creating the playback-capture `AudioRecord`. Skip
  either step and the call throws on Android 14+.
- **DJ mode — AudioPlaybackCapture opt-out:** apps may mark their audio stream
  `ALLOW_CAPTURE_BY_NONE` (common in Spotify, DRM'd content). Those streams are
  silently captured as silence — no error. YouTube-in-browser and local media files
  work fine.
- **DJ mode — MTU:** 48 kHz stereo uses 5 ms chunks (240 frames, 960-byte payload)
  to stay under the ~1500-byte Ethernet MTU. A 10 ms chunk would be ~1920 bytes and
  force IP fragmentation. Mic mode's 10 ms / 320-byte packet is safely under the limit.
- **DJ mode — u16 sample-rate field:** 48000 is written as
  `(48000 and 0xFFFF).toShort()` (two's complement wraps to -17536 signed). The
  receiver decodes with `struct.unpack(">H", ...)` (unsigned) to recover 48000. A
  naive signed `">h"` read would give -17536 and break resampling.
- **DJ mode — no auto-connect:** discovery auto-connect is intentionally disabled in
  DJ mode. Triggering `startDj` without a user gesture pops the system
  screen-capture consent dialog unexpectedly. The user must tap Start explicitly.
