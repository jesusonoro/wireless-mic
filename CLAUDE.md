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
- `sender/android/app/src/main/kotlin/com/wirelessmic/sender/AudioForegroundService.kt` — background audio streaming via ForegroundService
- `sender/android/app/src/main/kotlin/com/wirelessmic/sender/AudioStreamPlugin.kt` — Flutter↔native bridge
- `sender/android/app/src/main/kotlin/com/wirelessmic/sender/MainActivity.kt` — creates notification channel
- `sender/android/app/src/main/AndroidManifest.xml` — FOREGROUND_SERVICE permissions + service declaration
