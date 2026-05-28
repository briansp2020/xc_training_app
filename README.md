# XC Training Data

A mobile app that collects health and workout data from a runner's phone and uploads it to a server, so a cross country team can analyze training effectiveness.

Currently reads heart rate data from **Health Connect** on Android. iOS support (via HealthKit) is planned.

## Prerequisites

- Flutter 3.44+ ([install guide](https://docs.flutter.dev/get-started/install))
- Android device running Android 9+ (API 28+) with Health Connect installed
- USB debugging enabled on the device

## Getting Started

```bash
# Install dependencies
flutter pub get

# List connected devices
flutter devices

# Run on your Android phone
flutter run -d <your-device-id>
```

## Android Setup Notes

- **MainActivity** must extend `FlutterFragmentActivity` (not `FlutterActivity`) — required by the `health` package for the permission launcher to work.
- **minSdkVersion** is set to 28 (Android 9) for Health Connect compatibility.
- Health Connect permissions are declared in `AndroidManifest.xml` for: heart rate, steps, distance, sleep, and active energy burned.

## How It Works

1. On launch, the app checks if Health Connect permissions are already granted.
2. If not, tap **"Request Permissions"** to open the Health Connect permissions dialog.
3. Once granted, tap **"Read My Heart Rate"** to fetch the most recent heart rate reading from the last 24 hours.

## Tech Stack

- **Flutter** (Dart) — cross-platform framework
- **health** 13.3.1 — reads Health Connect (Android) / HealthKit (iOS)
- **http** 1.6.0 — for future server uploads
- **shared_preferences** 2.5.5 — for local state (e.g., last sync time)
