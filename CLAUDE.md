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
- `sender/android/app/src/main/kotlin/com/wirelessmic/sender/AudioForegroundService.kt` — background audio streaming via ForegroundService; also computes per-chunk peak mic level for the meter
- `sender/android/app/src/main/kotlin/com/wirelessmic/sender/AudioStreamPlugin.kt` — Flutter↔native bridge; holds the Wi-Fi `MulticastLock` during discovery
- `sender/android/app/src/main/kotlin/com/wirelessmic/sender/MainActivity.kt` — creates notification channel
- `sender/android/app/src/main/AndroidManifest.xml` — FOREGROUND_SERVICE permissions + service declaration
- `sender/lib/discovery/discovery_service.dart` — listens for receiver beacons (UDP :7356) → auto-connect
- `sender/lib/ui/sender_screen.dart` — auto-discovery UI, VU meter, manual fallback
- `receiver/receiver.py` — receiver + jitter buffer + discovery-beacon broadcaster; GUI auto-starts listening

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
