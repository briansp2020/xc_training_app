# XC Training Data

A Flutter app that uploads raw health data (the last 24 hours by default; incremental after the first sync) — heart rate samples, steps, distance, calories, sleep, and any explicit workout records — to a server for cross country team analysis. The client is a thin uploader; all analysis (including detecting workouts from raw HR + cadence) happens server-side.

Runs on **Android** (Health Connect) and **iOS** (HealthKit).

## Prerequisites

- Flutter 3.44+
- A server willing to accept ~15 MB JSON POSTs — see [docs/SERVER_SCHEMA.md](docs/SERVER_SCHEMA.md)
- **Android:** device on API 28+ with Health Connect installed and populated (Fitbit, Strava, Google Fit, Wear OS, etc.), USB debugging enabled
- **iOS:** macOS with the full **Xcode** + **CocoaPods**, and a **physical iPhone** — HealthKit and GPS routes don't exist on the Simulator. A free Apple ID signs dev builds onto your own device; TestFlight/App Store needs the paid Apple Developer Program. See [CLAUDE.md](CLAUDE.md) "iOS / HealthKit gotchas".

## Run

```bash
flutter pub get
flutter devices               # confirm your device is listed
```

Point the app at your server with `config/dev.json` (copy `config/dev.json.example`) — see [CLAUDE.md](CLAUDE.md) "Server config".

**Android:**

```bash
flutter run -d <device-id> --dart-define-from-file=config/dev.json
```

**iOS** — build and install via `devicectl` (more reliable than `flutter run` on Xcode 26; keep the iPhone **unlocked**, and use a **release** build — debug builds crash on ProMotion devices, see [CLAUDE.md](CLAUDE.md)):

```bash
flutter build ios --release --dart-define-from-file=config/dev.json
xcrun devicectl device install app --device <udid> build/ios/iphoneos/Runner.app
xcrun devicectl device process launch --device <udid> com.github.briansp2020.xctraining
```

## Current state

Working end-to-end on Android and iOS phones:

1. Google Sign-In (or dev-login) → server JWT; auto-detects/requests health permissions on launch
2. Reads all 19 supported streams (last 24 hours on first sync, incremental afterwards)
3. POSTs as `type: "health_sync"` to the configured server (verified accepted)

The DEBUG ONLY section of the UI also exposes **Discover Workout Data** (dumps last 5 workouts as raw JSON to the `flutter run` console) and **Scan All Data (30d)** (per-type counts and peak-HR-per-day summary) for ad-hoc schema discovery. Both will be removed before shipping.

## Roadmap

1. Server-side session detection — recovers Fitbit-tracked sessions that aren't wrapped in `ExerciseSessionRecord` (algorithm in [docs/SERVER_SCHEMA.md](docs/SERVER_SCHEMA.md))
2. Background sync via WorkManager
3. Strava OAuth server-side for GPS routes (never in Health Connect)
4. Multi-athlete: replace hardcoded `_athleteId = 1` with login / device token
5. iOS: TestFlight / App Store distribution (needs the paid Apple Developer Program)
6. Remove the debug-only UI section
7. HTTPS + drop the cleartext exceptions (`usesCleartextTraffic` on Android, `NSAllowsArbitraryLoads` on iOS)

## Where things live

- [lib/main.dart](lib/main.dart) — the whole app
- [docs/SERVER_SCHEMA.md](docs/SERVER_SCHEMA.md) — upload contract: payload shape, dedup strategy, suggested Postgres tables, session-detection algorithm
- [CLAUDE.md](CLAUDE.md) — coding conventions, server/auth config, and Android/Health Connect + iOS/HealthKit gotchas
