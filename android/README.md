# Is It Snappy? — Android port

A Kotlin port of the iOS app, measuring input-to-display latency the same way:
film the interaction with the phone's high-speed camera, then scrub frame-by-frame
and mark the input frame and the response frame.

## Behavior parity

- Capture uses CameraX 1.5 high-speed recording with a fallback ladder
  (240 → 120 → 60 → 30 fps, per what the device's camera actually supports; the
  chosen rate is shown on the capture screen). Devices with no high-speed support
  still work at normal rates.
- Frame stepping mirrors the iOS gestures: drag to scrub (same response curve
  constants as `MarkViewController`), tap the left/right screen edges to step
  single frames.
- Latency math is computed from the real per-frame presentation timestamps
  (a `MediaExtractor`-built PTS table, sorted into presentation order), never
  from `frame × nominal fps` — matching the iOS `frameTimes` construction,
  including the +1 ms epsilon.
- Marks are stored in seconds in an app-private JSON database with the same
  field semantics as the iOS `MarkDatabase`.
- Videos are app-private (`filesDir/captures/`); the app needs only the CAMERA
  permission, requested lazily on first capture like the iOS flow.

## Building

Requires JDK 17. No Android Studio needed:

```
cd android
./gradlew assembleDebug
# APK at app/build/outputs/apk/debug/app-debug.apk
```

minSdk 26, targetSdk 35. Dependencies are androidx + material only.

## Verification status

Exercised end-to-end on an emulator (capture → mark → persistence, permission
deny/grant flows, rotation, graceful degradation without high-speed support).
The constrained high-speed (240/120 fps) session path cannot run on an emulator
and has been validated against the CameraX documentation but not yet on
physical hardware.
