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

Both `_serverBase` and `_googleServerClientId` in `lib/main.dart` are read from `--dart-define`s at build time:

```
flutter run --dart-define-from-file=config/dev.json -d <device-id>
```

`config/dev.json` is per-developer and gitignored; copy `config/dev.json.example` to start. The defaults (when no flag is passed) are `http://10.0.2.2:8000` (the Android emulator's alias for the host's localhost) and an empty Google client ID (Google Sign-In disabled, dev-login still works).

From a physical phone use the host's LAN IP (e.g. `http://10.0.0.23:8000`), and the server must bind to `0.0.0.0`, not `127.0.0.1`. The manifest currently allows cleartext traffic; remove `android:usesCleartextTraffic="true"` when switching to HTTPS.

## Auth

Every request to the server needs `Authorization: Bearer <jwt>`. Two ways to get one:

1. **Google Sign-In** (`POST /auth/google`) — exchanges a Google ID token for the server JWT. Requires the Google Cloud Console setup below.
2. **Dev login** (`POST /auth/dev-login`) — accepts any email and issues a JWT. Only available when the server is run with `DEV_MODE=true`. No Cloud Console setup needed.

The token is persisted in `shared_preferences` and replayed on every sync. 401 responses drop the token and force the user back to the sign-in card. See `lib/auth_service.dart`.

### Google Sign-In setup (one-time per project)

1. Open the [Google Cloud Console](https://console.cloud.google.com/), create or select a project, and enable the **Identity Services API**.
2. **OAuth consent screen** → set up an "External" consent screen (Internal works only inside a Google Workspace org). Required scopes: `openid`, `email`, `profile`.
3. **Credentials** → **Create credentials** → **OAuth client ID**, twice:
   - **Web application** — this is the *audience* the server validates ID tokens against. Copy its client ID into `config/dev.json` as `GOOGLE_SERVER_CLIENT_ID` and tell the server about it too.
   - **Android** — package name `com.github.briansp2020.xctraining`, SHA-1 of the keystore you sign with. Get the debug SHA-1 with `keytool -list -v -keystore "%USERPROFILE%/.android/debug.keystore" -alias androiddebugkey -storepass android -keypass android`. Add the release SHA-1 once you have a release keystore.
4. Add test users on the OAuth consent screen until you publish the app — Google rejects sign-ins from accounts that aren't listed during the "Testing" phase.

The `google_sign_in` package (v7+) uses Android's Credential Manager API under the hood, so no `google-services.json` is required — just the OAuth client IDs registered above.

## Android / Health Connect gotchas

These bit us during development and aren't obvious from the code:

- `MainActivity` must extend `FlutterFragmentActivity`, not `FlutterActivity`. The `health` package's permission launcher uses `registerForActivityResult()` which needs a `ComponentActivity`.
- `Health().configure()` must be called before any other health operations — it registers the permission launcher. Without it you get "Permission launcher not found".
- Use `Health().hasPermissions()` on startup; don't force re-grant every launch.
- **Total vs Active calories are separate Health Connect permissions.** The `health` package's workout reader internally queries `TotalCaloriesBurnedRecord`, so the manifest needs `READ_TOTAL_CALORIES_BURNED` even though our Dart code uses `HealthDataType.ACTIVE_ENERGY_BURNED`. Without it, workout reads silently return empty (the package swallows the SecurityException).
- **Fitbit doesn't always write `ExerciseSessionRecord` for activities it tracks** — treadmill sessions in particular show up only as raw HR + step streams. This is why the server detects sessions from raw signals instead of trusting the explicit workouts list.
- Pixel Pro Fold has two displays. To screenshot the right one via adb: `screencap -p -d <display-id>`. To keep the screen on during dev: `adb shell settings put global stay_on_while_plugged_in 7`.
