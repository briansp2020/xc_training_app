# XC Training Data

A mobile app that collects health and workout data from a runner's phone (via Health Connect on Android, HealthKit on iOS) and uploads it to a server for cross country team training analysis. The app is a "tiny uploader" — its only job is to read health data and POST it to a server. All analysis and dashboards happen elsewhere.

## Tech Stack

- **Framework:** Flutter (Dart) — single codebase targeting Android first, iOS later
- **Health data:** `health` package (wraps Health Connect on Android, HealthKit on iOS)
- **HTTP:** `http` package (for future server uploads)
- **Local storage:** `shared_preferences` (stores simple state like last sync time)
- **Android language:** Kotlin
- **iOS language:** Swift
- **Min Android SDK:** 28 (Android 9+)

## Architecture

This app follows a "tiny uploader" pattern:
1. Read health data from the phone's health platform (Health Connect / HealthKit)
2. POST the data to a server endpoint
3. Track what has been synced so we don't re-upload

The app does NOT do analysis, charting, or dashboards. That's the server's job.

## Coding Conventions

- Follow standard Dart style (`dart format`, `flutter analyze` must pass)
- Prefer simple, readable code over clever abstractions
- Show errors to the user on screen — never silently swallow failures
- Comment only when the "why" is non-obvious

## Health Data Types We Read

- Heart rate
- Steps
- Distance
- Sleep
- Active energy burned

## Current State

**Week 1:** Single-screen app that requests Health Connect permissions and reads the most recent heart rate value. No server upload yet.

## Next Steps

1. Add remaining health data types to the UI (steps, distance, sleep, calories)
2. Build a simple server endpoint and implement the POST upload
3. Add `shared_preferences` tracking for last sync timestamp
4. Add a "Sync Now" button that reads all new data since last sync and uploads it
5. Handle background sync (WorkManager on Android)
6. iOS setup (HealthKit permissions, entitlements, Info.plist)
7. Add team/athlete identification (so the server knows which runner's data this is)
8. Polish: loading indicators, sync history, error retry
