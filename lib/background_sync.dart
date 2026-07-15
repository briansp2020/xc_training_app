// Headless background-sync entrypoint and shared body (background sync).
//
// [runBackgroundSyncBody] is the platform-independent core: load the saved
// session, sync if the user is signed in AND has automatic upload enabled,
// and record the outcome. It's shared by the iOS entrypoint here and the
// Android WorkManager callback (see main.dart) so the two can't drift.
//
// On iOS, AppDelegate registers a BGAppRefreshTask (and a HealthKit workout
// observer); when iOS grants a background wake it spins up a *headless*
// FlutterEngine running [backgroundSync] below — no widgets, no scenes. That
// entrypoint runs the shared body and reports completion back over the
// xctraining/background_sync channel so the task can be marked done before
// iOS's ~30s budget expires. Android has no such channel — WorkManager gets
// the result as the callback's return value.
//
// The result of every background attempt is persisted to shared_preferences
// ([lastBackgroundSyncPrefsKey]) so the debug page can show what happened —
// background runs are otherwise invisible.

import 'dart:io' show Platform;
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:health/health.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import 'auth_service.dart';
import 'sync_service.dart';

const String lastBackgroundSyncPrefsKey = 'last_background_sync';

// Android WorkManager task identifiers. The unique name dedups the scheduled
// work; the task name is echoed back to the callback (unused for now — there's
// only one kind of task).
const String androidSyncUniqueName = 'chadwick-periodic-sync';
const String androidSyncTaskName = 'sync';

// The user's automatic-upload choice (also the final onboarding step). Written
// by the toggle in main.dart, read here to gate background syncs — background
// upload respects the same switch as sync-on-open. Single source of truth for
// the key: main.dart imports it from here.
const String autoSyncPrefsKey = 'auto_sync_enabled';

/// Runs one headless sync if appropriate, records the outcome, and returns
/// whether a sync actually succeeded. Never throws. Assumes the Flutter
/// binding + plugin registrant are already initialized (each entrypoint does
/// that before calling). Shared by iOS ([backgroundSync]) and Android's
/// WorkManager callback.
Future<bool> runBackgroundSyncBody(String trigger) async {
  var success = false;
  var summary = 'not signed in — skipped';
  try {
    // Google Sign-In isn't needed here — only the persisted server JWT.
    final auth = AuthService(serverBase: serverBase, googleServerClientId: '');
    await auth.load();
    final prefs = await SharedPreferences.getInstance();
    final autoUpload = prefs.getBool(autoSyncPrefsKey) ?? false;
    if (!auth.isSignedIn) {
      summary = 'not signed in — skipped';
    } else if (!autoUpload) {
      summary = 'automatic upload off — skipped';
    } else {
      final health = Health();
      await health.configure();
      final result = await SyncService(auth: auth, health: health).sync();
      success = result.status == SyncStatus.ok;
      summary = '${result.status.name}: ${result.message}';
    }
  } catch (e) {
    summary = 'error: $e';
  }

  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      lastBackgroundSyncPrefsKey,
      '${DateTime.now()} (trigger: $trigger)\n$summary',
    );
  } catch (_) {
    // Recording the outcome is best-effort — never block task completion.
  }
  return success;
}

@pragma('vm:entry-point')
Future<void> backgroundSync(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  const channel = MethodChannel('xctraining/background_sync');
  // AppDelegate tags each run with what woke us: "bg-app-refresh" (periodic
  // BGAppRefreshTask) or "healthkit" (new workout landed).
  final trigger = args.isEmpty ? 'unknown' : args.first;

  final success = await runBackgroundSyncBody(trigger);

  try {
    await channel.invokeMethod('done', success);
  } catch (_) {
    // If the native side is already gone (task expired), there's no one to
    // tell — the expiration handler has completed the task for us.
  }
}

// Android WorkManager entrypoint. Registered via Workmanager().initialize in
// main() (Android only — iOS uses the BGTask path above). WorkManager wakes a
// headless isolate and calls this, which runs the shared body. Returning the
// success bool lets WorkManager retry (per the task's backoff policy) on
// failure.
@pragma('vm:entry-point')
void workManagerCallbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    // executeTask initializes the widgets binding; the plugin registrant is
    // needed too so the health / shared_preferences channels work here.
    DartPluginRegistrant.ensureInitialized();
    return runBackgroundSyncBody('workmanager:$taskName');
  });
}

// Registers (or updates) the periodic Android background sync — WorkManager
// wakes the app about every 15 min (its floor) when a network is available and
// runs one sync. Idempotent: dedups by unique name, and `update` refreshes the
// spec without disrupting timing. No-op on iOS, which uses the native BGTask
// path. Call when the user is onboarded with automatic upload on.
Future<void> scheduleAndroidSync() async {
  if (!Platform.isAndroid) return;
  await Workmanager().registerPeriodicTask(
    androidSyncUniqueName,
    androidSyncTaskName,
    frequency: const Duration(minutes: 15),
    constraints: Constraints(networkType: NetworkType.connected),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
  );
}

// Cancels the periodic background sync. Call when the user turns automatic
// upload off or signs out. No-op on iOS.
Future<void> cancelAndroidSync() async {
  if (!Platform.isAndroid) return;
  await Workmanager().cancelByUniqueName(androidSyncUniqueName);
}
