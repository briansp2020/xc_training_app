// Headless background-sync entrypoint (background sync phase 2).
//
// On iOS, AppDelegate registers a BGAppRefreshTask; when iOS grants a
// background wake it spins up a *headless* FlutterEngine running
// [backgroundSync] below — no widgets, no scenes. The entrypoint runs one
// SyncService.sync() and reports completion back over the
// xctraining/background_sync channel so the task can be marked done before
// iOS's ~30s budget expires.
//
// The result of every background attempt is persisted to shared_preferences
// ([lastBackgroundSyncPrefsKey]) so the debug page can show what happened —
// background runs are otherwise invisible.

import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:health/health.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_service.dart';
import 'sync_service.dart';

const String lastBackgroundSyncPrefsKey = 'last_background_sync';

@pragma('vm:entry-point')
Future<void> backgroundSync() async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  const channel = MethodChannel('xctraining/background_sync');

  var success = false;
  var summary = 'not signed in — skipped';
  try {
    // Google Sign-In isn't needed here — only the persisted server JWT.
    final auth = AuthService(serverBase: serverBase, googleServerClientId: '');
    await auth.load();
    if (auth.isSignedIn) {
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
      '${DateTime.now()}\n$summary',
    );
  } catch (_) {
    // Recording the outcome is best-effort — never block task completion.
  }

  try {
    await channel.invokeMethod('done', success);
  } catch (_) {
    // If the native side is already gone (task expired), there's no one to
    // tell — the expiration handler has completed the task for us.
  }
}
