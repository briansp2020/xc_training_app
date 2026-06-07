# XC Training Data — developer notes

See [README.md](README.md) for what this project is, how to run it, current state, and roadmap. See [docs/SERVER_SCHEMA.md](docs/SERVER_SCHEMA.md) for the upload contract.

This file covers things that aren't obvious from reading the code.

## Tech stack

- Flutter 3.44, Dart 3.x
- `health` ^13.3.1 (Health Connect on Android, HealthKit on iOS)
- `http` ^1.6.0
- `shared_preferences` ^2.5.5 (declared, not yet used — will hold last-sync timestamp)
- Kotlin on Android, Swift on iOS, minSdk 28

## Coding conventions

- `dart format` clean, `flutter analyze` must pass
- Prefer simple, readable code over clever abstractions
- Surface errors to the user on screen — never silently swallow
- Comment only when the "why" is non-obvious

## Server config

`_serverUrl` constant at the top of `lib/main.dart`. From the Android emulator: `http://10.0.2.2:8000/workouts`. From a physical phone: the host's LAN IP (e.g. `http://10.0.0.23:8000/workouts`), and the server must bind to `0.0.0.0`, not `127.0.0.1`. The manifest currently allows cleartext traffic; remove `android:usesCleartextTraffic="true"` when switching to HTTPS.

## Android / Health Connect gotchas

These bit us during development and aren't obvious from the code:

- `MainActivity` must extend `FlutterFragmentActivity`, not `FlutterActivity`. The `health` package's permission launcher uses `registerForActivityResult()` which needs a `ComponentActivity`.
- `Health().configure()` must be called before any other health operations — it registers the permission launcher. Without it you get "Permission launcher not found".
- Use `Health().hasPermissions()` on startup; don't force re-grant every launch.
- **Total vs Active calories are separate Health Connect permissions.** The `health` package's workout reader internally queries `TotalCaloriesBurnedRecord`, so the manifest needs `READ_TOTAL_CALORIES_BURNED` even though our Dart code uses `HealthDataType.ACTIVE_ENERGY_BURNED`. Without it, workout reads silently return empty (the package swallows the SecurityException).
- **Fitbit doesn't always write `ExerciseSessionRecord` for activities it tracks** — treadmill sessions in particular show up only as raw HR + step streams. This is why the server detects sessions from raw signals instead of trusting the explicit workouts list.
- Pixel Pro Fold has two displays. To screenshot the right one via adb: `screencap -p -d <display-id>`. To keep the screen on during dev: `adb shell settings put global stay_on_while_plugged_in 7`.
