# XC Training Data

A Flutter app that uploads 30 days of raw Health Connect data — heart rate samples, steps, distance, calories, sleep, and any explicit workout records — to a server for cross country team analysis. The client is a thin uploader; all analysis (including detecting workouts from raw HR + cadence) happens server-side.

Android only for now. iOS support is on the roadmap.

## Prerequisites

- Flutter 3.44+
- Android device on API 28+ with Health Connect installed and populated (Fitbit, Strava, Google Fit, Wear OS, etc.)
- USB debugging enabled
- A server willing to accept ~15 MB JSON POSTs — see [docs/SERVER_SCHEMA.md](docs/SERVER_SCHEMA.md)

## Run

```bash
flutter pub get
flutter devices               # confirm your phone is listed
flutter run -d <device-id>
```

Update `_serverUrl` at the top of [lib/main.dart](lib/main.dart) to point at your server.

## Current state

Working end-to-end on one Android phone:

1. Auto-detects/requests Health Connect permissions on launch
2. Reads 30 days of all 19 supported streams
3. POSTs as `type: "health_sync"` to the configured server (verified accepted)

The DEBUG ONLY section of the UI also exposes **Discover Workout Data** (dumps last 5 workouts as raw JSON to the `flutter run` console) and **Scan All Data (30d)** (per-type counts and peak-HR-per-day summary) for ad-hoc schema discovery. Both will be removed before shipping.

## Roadmap

1. Server-side session detection — recovers Fitbit-tracked sessions that aren't wrapped in `ExerciseSessionRecord` (algorithm in [docs/SERVER_SCHEMA.md](docs/SERVER_SCHEMA.md))
2. Track `last_sync_at` in `shared_preferences` so re-syncs only POST new data
3. Background sync via WorkManager
4. Strava OAuth server-side for GPS routes (never in Health Connect)
5. Multi-athlete: replace hardcoded `_athleteId = 1` with login / device token
6. iOS support (HealthKit permissions, entitlements, Info.plist)
7. Remove the debug-only UI section
8. HTTPS + drop the `usesCleartextTraffic` flag

## Where things live

- [lib/main.dart](lib/main.dart) — the whole app
- [docs/SERVER_SCHEMA.md](docs/SERVER_SCHEMA.md) — upload contract: payload shape, dedup strategy, suggested Postgres tables, session-detection algorithm
- [CLAUDE.md](CLAUDE.md) — coding conventions and Android/Health Connect gotchas
