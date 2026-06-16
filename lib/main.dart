import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:health/health.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_service.dart';

// Server BASE URL (no trailing path). Override at run time:
//   flutter run --dart-define-from-file=config/dev.json
// (see config/dev.json.example for the schema). The default value below is
// the Android emulator's alias for the host machine's localhost — safe as a
// fall-back for someone freshly cloning the repo.
//
// Endpoints constructed from this base:
//   $_serverBase/workouts          — health sync (POST)
//   $_serverBase/auth/google       — exchange Google ID token → server JWT
//   $_serverBase/auth/dev-login    — dev-only: email-based JWT (DEV_MODE=true)
const String _serverBase = String.fromEnvironment(
  'SERVER_URL',
  defaultValue: 'http://10.0.2.2:8000',
);

// Google Cloud Console OAuth 2.0 **web** client ID (the audience the server
// validates ID tokens against). Set via --dart-define-from-file=config/dev.json
// — see CLAUDE.md "Google Sign-In setup" for the Cloud Console steps. Empty
// disables Google Sign-In; dev-login still works.
const String _googleServerClientId = String.fromEnvironment(
  'GOOGLE_SERVER_CLIENT_ID',
  defaultValue: '',
);

// Server attributes uploads to the athlete in the Bearer token; this field
// is now deprecated and ignored, but kept in the payload so older server
// builds still parse the request.
const int _athleteId = 1;

// Reported in every sync payload so the server can tell which client emitted
// it. Must match `version` in pubspec.yaml — bump both together.
const String _clientVersion = '1.0.0+1';

// shared_preferences key — stores the ISO-8601 UTC timestamp of the most
// recent successful sync. Next sync uses this as window_start. Falls back to
// 30 days ago when absent (first run or after a reinstall).
const String _lastSyncPrefsKey = 'last_sync_at';
const Duration _firstSyncWindow = Duration(days: 30);

// Re-query a small overlap behind the watermark on every incremental sync,
// to catch late-arriving Health Connect samples (Fitbit can batch-deliver
// data 30-60 minutes after the sensor reading happened). Server's UUID
// upsert dedup makes the duplicates harmless.
const Duration _watermarkOverlap = Duration(hours: 1);

// One GPS fix in a recorded route. Serialized to the local track JSON; this
// shape is what a future server route-upload endpoint will consume.
class _TrackPoint {
  final double lat;
  final double lng;
  final DateTime time;
  final double accuracy; // meters
  final double altitude; // meters
  final double speed; // m/s

  _TrackPoint({
    required this.lat,
    required this.lng,
    required this.time,
    required this.accuracy,
    required this.altitude,
    required this.speed,
  });

  Map<String, dynamic> toJson() => {
        'lat': lat,
        'lng': lng,
        'time': time.toUtc().toIso8601String(),
        'accuracy_m': accuracy,
        'altitude_m': altitude,
        'speed_mps': speed,
      };
}

void main() {
  runApp(const XCTrainingApp());
}

class XCTrainingApp extends StatelessWidget {
  const XCTrainingApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'XC Training Data',
      theme: ThemeData(
        colorSchemeSeed: Colors.green,
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final Health _health = Health();
  final AuthService _auth = AuthService(
    serverBase: _serverBase,
    googleServerClientId: _googleServerClientId,
  );

  String _status = 'Initializing Health Connect...';
  bool _configured = false;
  bool _permissionsGranted = false;
  bool _uploading = false;
  bool _authLoading = true;
  String? _heartRateValue;
  String? _heartRateTime;

  // DIY GPS route recording (foreground only for now). _track accumulates fixes
  // while _recording; _distanceMeters is summed incrementally between fixes.
  bool _recording = false;
  final List<_TrackPoint> _track = [];
  double _distanceMeters = 0;
  DateTime? _recordStart;
  Duration _elapsed = Duration.zero;
  StreamSubscription<Position>? _posSub;
  Timer? _tick;

  // Bottom-nav page index. Page 0 = Home (production UI), page 1 = Debug
  // tools. The Debug page + its nav tab exist only in debug builds.
  int _pageIndex = 0;

  // Single source of truth for what the sync reads + what we request permission
  // for. Must match the manifest's READ_* declarations and the union of
  // _numericStreams + _intervalStreams + [WORKOUT].
  final List<HealthDataType> _types = [
    // Core training signals
    HealthDataType.HEART_RATE,
    HealthDataType.STEPS,
    HealthDataType.DISTANCE_DELTA,
    HealthDataType.ACTIVE_ENERGY_BURNED,
    // TOTAL_CALORIES_BURNED is required even though we never directly read
    // it via this list: the health package's WORKOUT reader internally
    // queries TotalCaloriesBurnedRecord to aggregate calories, and the read
    // returns empty without this permission.
    HealthDataType.TOTAL_CALORIES_BURNED,
    HealthDataType.WORKOUT,
    // Recovery / fitness extras
    HealthDataType.HEART_RATE_VARIABILITY_RMSSD,
    HealthDataType.RESTING_HEART_RATE,
    HealthDataType.RESPIRATORY_RATE,
    // Sleep — READ_SLEEP covers SLEEP_ASLEEP and the stage types.
    HealthDataType.SLEEP_ASLEEP,
    HealthDataType.SLEEP_SESSION,
    HealthDataType.SLEEP_DEEP,
    HealthDataType.SLEEP_REM,
    HealthDataType.SLEEP_LIGHT,
    HealthDataType.SLEEP_AWAKE,
  ];

  // All types are READ-only. The debug "Insert Test Workout" button no longer
  // needs WRITE; if you re-enable it, switch HEART_RATE, DISTANCE_DELTA, and
  // WORKOUT back to READ_WRITE here (and grant WRITE in Health Connect).
  List<HealthDataAccess> get _permissions =>
      _types.map((_) => HealthDataAccess.READ).toList();

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await _auth.load();
    if (!mounted) return;
    setState(() {
      _authLoading = false;
    });
    await _configureHealth();
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _tick?.cancel();
    super.dispose();
  }

  // ---- DIY GPS route recording (Milestone A: foreground + local save) ----

  // Ensures GPS is on and we hold at least while-in-use location permission.
  // Background ("Allow all the time") is a later milestone.
  Future<bool> _ensureLocationPermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      setState(() => _status = 'Location is off — enable GPS, then start the run.');
      return false;
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      setState(() => _status =
          'Location permission denied. Grant it in Settings to record runs.');
      return false;
    }
    return true;
  }

  Future<void> _startRecording() async {
    if (!await _ensureLocationPermission()) return;
    if (!mounted) return;
    setState(() {
      _recording = true;
      _track.clear();
      _distanceMeters = 0;
      _elapsed = Duration.zero;
      _recordStart = DateTime.now();
      _status = 'Recording run — keep the app open (background comes later).';
    });

    const settings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 5, // meters between fixes — filters GPS jitter at rest
    );
    _posSub = Geolocator.getPositionStream(locationSettings: settings).listen(
      (pos) {
        if (!mounted) return;
        setState(() {
          if (_track.isNotEmpty) {
            final last = _track.last;
            _distanceMeters += Geolocator.distanceBetween(
                last.lat, last.lng, pos.latitude, pos.longitude);
          }
          _track.add(_TrackPoint(
            lat: pos.latitude,
            lng: pos.longitude,
            time: pos.timestamp,
            accuracy: pos.accuracy,
            altitude: pos.altitude,
            speed: pos.speed,
          ));
        });
      },
      onError: (e) {
        if (!mounted) return;
        setState(() => _status = 'GPS error: $e');
      },
    );

    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _recordStart == null) return;
      setState(() => _elapsed = DateTime.now().difference(_recordStart!));
    });
  }

  Future<void> _stopRecording() async {
    final end = DateTime.now();
    await _posSub?.cancel();
    _posSub = null;
    _tick?.cancel();
    _tick = null;
    final points = _track.toList();
    if (!mounted) return;
    setState(() => _recording = false);

    if (points.isEmpty) {
      setState(() => _status = 'Stopped — no GPS fixes captured.');
      return;
    }

    // end_time is the stop moment (not the last GPS fix) so it stays
    // consistent with duration — the tail of a run can be still, producing
    // no new fixes, which would otherwise make end_time lag the real stop.
    final start = _recordStart ?? points.first.time;
    final duration = end.difference(start);
    final payload = {
      'type': 'route_track',
      'source': 'diy_gps',
      'recorded_at': end.toUtc().toIso8601String(),
      'start_time': start.toUtc().toIso8601String(),
      'end_time': end.toUtc().toIso8601String(),
      'duration_seconds': duration.inSeconds,
      'distance_meters': _distanceMeters,
      'point_count': points.length,
      'points': [for (final p in points) p.toJson()],
    };

    try {
      final dir = await getApplicationDocumentsDirectory();
      final stamp =
          start.toUtc().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
      final file = File('${dir.path}/xc_route_$stamp.json');
      await file.writeAsString(jsonEncode(payload));
      if (!mounted) return;
      setState(() {
        _status = 'Saved run: ${(_distanceMeters / 1000).toStringAsFixed(2)} km, '
            '${_fmtDuration(duration)}, ${points.length} points\n→ ${file.path}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Failed to save run: $e');
    }
  }

  String _fmtDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  Future<void> _signInWithGoogle() async {
    setState(() => _status = 'Signing in with Google...');
    final err = await _auth.signInWithGoogle();
    if (!mounted) return;
    setState(() {
      _status = err ?? 'Signed in as ${_auth.email ?? _auth.name ?? "(unknown)"}.';
    });
  }

  Future<void> _signInWithDevEmail() async {
    final controller = TextEditingController(text: _auth.email ?? '');
    final email = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Dev sign-in'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Email to sign in as. The server must be running '
                'with DEV_MODE=true for this to work.'),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                labelText: 'Email',
                hintText: 'you@example.com',
              ),
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('Sign in'),
          ),
        ],
      ),
    );
    if (email == null || email.trim().isEmpty) return;
    if (!mounted) return;
    setState(() => _status = 'Signing in as $email...');
    final err = await _auth.signInWithDevEmail(email);
    if (!mounted) return;
    setState(() {
      _status = err ?? 'Signed in as ${_auth.email ?? email}.';
    });
  }

  Future<void> _signOut() async {
    await _auth.signOut();
    if (!mounted) return;
    setState(() => _status = 'Signed out.');
  }

  Widget _buildAuthCard(ThemeData theme) {
    // Hide the auth UI entirely until prefs are loaded — avoids the brief
    // "not signed in" flash on a returning user.
    if (_authLoading) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16.0),
          child: Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 12),
              Text('Loading saved session...'),
            ],
          ),
        ),
      );
    }

    if (_auth.isSignedIn) {
      final label = _auth.email ?? _auth.name ?? 'Signed in';
      return Card(
        color: theme.colorScheme.secondaryContainer,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(
            children: [
              Icon(Icons.account_circle,
                  color: theme.colorScheme.onSecondaryContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: theme.colorScheme.onSecondaryContainer,
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton(
                onPressed: _signOut,
                child: const Text('Sign out'),
              ),
            ],
          ),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Sign in to sync', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              'Your athlete identity is read from the bearer token the '
              'server issues — pick a sign-in method.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed:
                  _auth.isGoogleConfigured ? _signInWithGoogle : null,
              icon: const Icon(Icons.login),
              label: Text(_auth.isGoogleConfigured
                  ? 'Sign in with Google'
                  : 'Google Sign-In not configured'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _signInWithDevEmail,
              icon: const Icon(Icons.developer_mode),
              label: const Text('Dev sign-in (server DEV_MODE only)'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _configureHealth() async {
    try {
      await _health.configure();
      if (!mounted) return;
      _configured = true;
      await _checkPermissions();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = 'Error initializing Health Connect: $e';
      });
    }
  }

  Future<void> _checkPermissions() async {
    try {
      final hasPermissions = await _health.hasPermissions(
        _types,
        permissions: _permissions,
      );
      if (!mounted) return;

      setState(() {
        _permissionsGranted = hasPermissions ?? false;
        _status = _permissionsGranted
            ? 'Permissions granted. Ready to read data!'
            : 'Tap "Request Permissions" to get started.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = 'Error checking permissions: $e';
      });
    }
  }

  Future<void> _requestPermissions() async {
    if (!_configured) {
      setState(() => _status = 'Health Connect not ready yet. Please wait...');
      return;
    }

    setState(() => _status = 'Requesting permissions...');

    try {
      final requested = await _health.requestAuthorization(
        _types,
        permissions: _permissions,
      );
      if (!mounted) return;

      setState(() {
        _permissionsGranted = requested;
        _status = requested
            ? 'Permissions granted!'
            : 'Permissions denied. Open Health Connect settings to grant access.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = 'Error requesting permissions: $e';
        _permissionsGranted = false;
      });
    }
  }

  // ============================================================
  // DEBUG ONLY — Schema discovery. Remove this method (and the
  // button below) before shipping.
  //
  // Reads the most recent 5 workouts from the last 90 days and
  // dumps the FULL HealthDataPoint JSON for each — every field,
  // null or not. Then, for each workout's time window, probes a
  // broad set of training-relevant HealthDataTypes and shows what
  // samples (if any) are available.
  //
  // Output goes to the console via debugPrint — watch the
  // `flutter run` terminal.
  // ============================================================
  Future<void> _discoverWorkoutData() async {
    setState(() {
      _uploading = true;
      _status = 'Discovering — watch the console output...';
    });

    const indent = JsonEncoder.withIndent('  ');

    // All training-relevant types the package exposes on Android.
    // Types we don't have READ permission for will come back empty
    // (the package catches SecurityException internally), which is
    // itself useful info — you'll see exactly which types are
    // accessible vs blocked.
    const probeTypes = <HealthDataType>[
      HealthDataType.HEART_RATE,
      HealthDataType.HEART_RATE_VARIABILITY_RMSSD,
      HealthDataType.RESTING_HEART_RATE,
      HealthDataType.STEPS,
      HealthDataType.DISTANCE_DELTA,
      HealthDataType.SPEED,
      HealthDataType.ACTIVE_ENERGY_BURNED,
      HealthDataType.TOTAL_CALORIES_BURNED,
      HealthDataType.BASAL_ENERGY_BURNED,
      HealthDataType.RESPIRATORY_RATE,
      HealthDataType.BLOOD_OXYGEN,
      HealthDataType.BODY_TEMPERATURE,
      HealthDataType.SKIN_TEMPERATURE,
      HealthDataType.FLIGHTS_CLIMBED,
      HealthDataType.ACTIVITY_INTENSITY,
      HealthDataType.WORKOUT_ROUTE,
    ];

    final bar = '=' * 70;
    final sub = '-' * 70;

    try {
      final now = DateTime.now();
      final ninetyDaysAgo = now.subtract(const Duration(days: 90));

      debugPrint('\n$bar');
      debugPrint('[DISCOVERY] Reading workouts from last 90 days');
      debugPrint(bar);

      final workouts = await _health.getHealthDataFromTypes(
        types: [HealthDataType.WORKOUT],
        startTime: ninetyDaysAgo,
        endTime: now,
      );

      if (!mounted) return;
      if (workouts.isEmpty) {
        debugPrint('[DISCOVERY] No workouts found in last 90 days.');
        setState(() {
          _uploading = false;
          _status = 'No workouts found. See console.';
        });
        return;
      }

      workouts.sort((a, b) => b.dateFrom.compareTo(a.dateFrom));
      final recent = workouts.take(5).toList();
      debugPrint(
          '[DISCOVERY] Found ${workouts.length} workouts; inspecting ${recent.length} most recent.');

      for (var i = 0; i < recent.length; i++) {
        final w = recent[i];
        debugPrint('\n$sub');
        debugPrint('[DISCOVERY] Workout ${i + 1}/${recent.length}');
        debugPrint(sub);

        debugPrint('Full HealthDataPoint JSON:');
        try {
          debugPrint(indent.convert(w.toJson()));
        } catch (e) {
          debugPrint('  (toJson failed: $e)');
          debugPrint('  toString: ${w.toString()}');
        }

        debugPrint(
            '\nProbing related data types in window [${w.dateFrom.toIso8601String()} .. ${w.dateTo.toIso8601String()}]:');

        for (final t in probeTypes) {
          try {
            final samples = await _health.getHealthDataFromTypes(
              types: [t],
              startTime: w.dateFrom,
              endTime: w.dateTo,
            );
            if (samples.isEmpty) {
              debugPrint('  ${t.name}: 0 samples (no data, or permission missing)');
              continue;
            }
            debugPrint('  ${t.name}: ${samples.length} sample(s)');
            // Dump the first sample in full; summarize the rest.
            try {
              final first = indent.convert(samples.first.toJson());
              debugPrint('    sample[0]:');
              for (final line in first.split('\n')) {
                debugPrint('      $line');
              }
            } catch (e) {
              debugPrint('    sample[0] toString: ${samples.first.toString()}');
            }
            if (samples.length > 1) {
              debugPrint(
                  '    ...${samples.length - 1} additional sample(s) elided');
            }
          } catch (e) {
            debugPrint('  ${t.name}: ERROR ($e)');
          }
        }
      }

      debugPrint('\n$bar');
      debugPrint('[DISCOVERY] Complete.');
      debugPrint('$bar\n');

      if (!mounted) return;
      setState(() {
        _uploading = false;
        _status =
            'Discovery complete: ${recent.length} workout(s) dumped. Check console.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _status = 'Discovery error: $e';
      });
    }
  }

  // ============================================================
  // DEBUG ONLY — Wide-net discovery. Remove with the others
  // before shipping.
  //
  // Unlike _discoverWorkoutData (which only looks inside
  // ExerciseSessionRecord windows), this scans the FULL 30-day
  // window for every training-relevant HealthDataType and shows:
  //   - count + source breakdown per type
  //   - first sample per non-empty type
  //   - top-20 step bursts by step-rate (treadmill candidates
  //     would appear here even with no workout wrapper)
  //   - daily peak heart rate (treadmill sessions push peaks)
  //
  // Use this to figure out whether activity Health Connect
  // ISN'T classifying as workouts is still present as raw data.
  // ============================================================
  Future<void> _discoverAllData() async {
    setState(() {
      _uploading = true;
      _status = 'Scanning 30 days of all data types — watch console...';
    });

    const indent = JsonEncoder.withIndent('  ');
    final bar = '=' * 70;

    const allTypes = <HealthDataType>[
      HealthDataType.WORKOUT,
      HealthDataType.HEART_RATE,
      HealthDataType.HEART_RATE_VARIABILITY_RMSSD,
      HealthDataType.RESTING_HEART_RATE,
      HealthDataType.STEPS,
      HealthDataType.DISTANCE_DELTA,
      HealthDataType.SPEED,
      HealthDataType.ACTIVE_ENERGY_BURNED,
      HealthDataType.TOTAL_CALORIES_BURNED,
      HealthDataType.BASAL_ENERGY_BURNED,
      HealthDataType.RESPIRATORY_RATE,
      HealthDataType.BLOOD_OXYGEN,
      HealthDataType.BODY_TEMPERATURE,
      HealthDataType.SKIN_TEMPERATURE,
      HealthDataType.FLIGHTS_CLIMBED,
      HealthDataType.ACTIVITY_INTENSITY,
      HealthDataType.SLEEP_SESSION,
      HealthDataType.SLEEP_ASLEEP,
      HealthDataType.SLEEP_DEEP,
      HealthDataType.SLEEP_REM,
      HealthDataType.WEIGHT,
      HealthDataType.HEIGHT,
      HealthDataType.BODY_FAT_PERCENTAGE,
      HealthDataType.WATER,
    ];

    try {
      final now = DateTime.now();
      final thirtyDaysAgo = now.subtract(const Duration(days: 30));

      debugPrint('\n$bar');
      debugPrint(
          '[ALL DATA] 30-day window: ${thirtyDaysAgo.toIso8601String()} -> ${now.toIso8601String()}');
      debugPrint(bar);

      final results = <HealthDataType, List<HealthDataPoint>>{};
      for (final t in allTypes) {
        results[t] = await _safeRead(t, thirtyDaysAgo, now);
      }

      debugPrint('\nPer-type summary (count, sources):');
      debugPrint('-' * 70);
      for (final entry in results.entries) {
        final samples = entry.value;
        final sourceCounts = <String, int>{};
        for (final s in samples) {
          sourceCounts[s.sourceName] = (sourceCounts[s.sourceName] ?? 0) + 1;
        }
        final sourceStr = sourceCounts.isEmpty
            ? '-'
            : sourceCounts.entries.map((e) => '${e.key}=${e.value}').join(', ');
        debugPrint(
            '${entry.key.name.padRight(36)} ${samples.length.toString().padLeft(5)}   $sourceStr');
      }

      debugPrint('\n\nFirst sample of each non-empty type:');
      for (final entry in results.entries) {
        if (entry.value.isEmpty) continue;
        debugPrint(
            '\n--- ${entry.key.name} (${entry.value.length} samples) ---');
        try {
          debugPrint(indent.convert(entry.value.first.toJson()));
        } catch (e) {
          debugPrint(entry.value.first.toString());
        }
      }

      // Top step bursts — treadmill activity should appear here as
      // high steps-per-minute, even if it never got a workout wrapper.
      final steps = results[HealthDataType.STEPS] ?? [];
      if (steps.isNotEmpty) {
        debugPrint('\n\n$bar');
        debugPrint('STEPS — top 20 records by step-rate (steps/min):');
        debugPrint(bar);
        final scored = <MapEntry<double, HealthDataPoint>>[];
        for (final s in steps) {
          final v = s.value;
          final count =
              v is NumericHealthValue ? v.numericValue.toDouble() : 0.0;
          final seconds = s.dateTo.difference(s.dateFrom).inSeconds;
          final rate = seconds > 0 ? count / (seconds / 60.0) : count;
          scored.add(MapEntry(rate, s));
        }
        scored.sort((a, b) => b.key.compareTo(a.key));
        for (final entry in scored.take(20)) {
          final s = entry.value;
          final v = s.value;
          final count = v is NumericHealthValue ? v.numericValue : 0;
          final dur = s.dateTo.difference(s.dateFrom);
          debugPrint(
              '  ${s.dateFrom.toLocal()}  +${dur.inSeconds}s: $count steps '
              '(${entry.key.toStringAsFixed(1)} spm)  ${s.sourceName}');
        }
      }

      // Daily peak HR — treadmill runs push peaks well above resting.
      final hr = results[HealthDataType.HEART_RATE] ?? [];
      if (hr.isNotEmpty) {
        debugPrint('\n\n$bar');
        debugPrint('HEART_RATE — daily peak BPM:');
        debugPrint(bar);
        final byDay = <String, num>{};
        for (final s in hr) {
          final v = s.value;
          if (v is! NumericHealthValue) continue;
          final day = s.dateFrom.toLocal().toString().substring(0, 10);
          final bpm = v.numericValue;
          if ((byDay[day] ?? 0) < bpm) byDay[day] = bpm;
        }
        final days = byDay.keys.toList()..sort();
        for (final d in days) {
          debugPrint('  $d: peak ${byDay[d]} BPM');
        }
      }

      debugPrint('\n$bar');
      debugPrint('[ALL DATA] Complete');
      debugPrint(bar);

      if (!mounted) return;
      final nonEmpty = results.entries.where((e) => e.value.isNotEmpty).length;
      setState(() {
        _uploading = false;
        _status =
            'Scan complete: $nonEmpty/${allTypes.length} types had data. Check console.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _status = 'Scan error: $e';
      });
    }
  }

  // ============================================================
  // DEBUG ONLY — Export current Health Connect data to a JSON file
  // on external storage. Use case: pull the file via adb and push it
  // into an emulator for testing the server's session-detection
  // algorithm against real data without re-syncing the phone.
  //
  // Output: /storage/emulated/0/Android/data/com.github.briansp2020.xctraining/files/health_export.json
  // ============================================================
  Future<void> _exportToFile() async {
    setState(() {
      _uploading = true;
      _status = 'Reading 30 days for export...';
    });

    try {
      final now = DateTime.now();
      final windowStart = now.subtract(_firstSyncWindow);

      final built =
          await _buildSyncPayload(windowStart, now, labelSuffix: ' (export)');
      if (!mounted) return;
      final payload = built.payload;
      final workoutCount = (payload['workouts'] as List).length;

      final dir = await getExternalStorageDirectory();
      if (!mounted) return;
      if (dir == null) {
        throw Exception('External storage directory unavailable');
      }
      final file = File('${dir.path}/health_export.json');
      // Compact (not indented) — the file is just for transfer.
      await file.writeAsString(jsonEncode(payload), flush: true);
      if (!mounted) return;

      final sizeMB = (await file.length() / 1024 / 1024).toStringAsFixed(2);
      setState(() {
        _uploading = false;
        _status = 'Exported $sizeMB MB '
            '($workoutCount workouts, ${built.totalSamples} samples) to:\n'
            '${file.path}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _status = 'Export error: $e';
      });
    }
  }

  // ============================================================
  // DEBUG ONLY — Read the export file and replay it into Health
  // Connect via the health package's write APIs. Intended for use
  // on an emulator that has just been wiped; running it on a phone
  // that already has the data will create duplicates (Health
  // Connect doesn't dedup by our UUIDs — it assigns its own on
  // write).
  //
  // Types we can write: HEART_RATE, STEPS, DISTANCE_DELTA,
  // ACTIVE_ENERGY_BURNED, TOTAL_CALORIES_BURNED, SLEEP_SESSION, and
  // WORKOUT. The other streams (HRV, resting HR, respiratory rate,
  // sleep stages) get skipped — the package doesn't expose writes
  // for them today. We log the skips so it's obvious in the
  // console what didn't round-trip.
  // ============================================================
  Future<void> _importFromFile() async {
    setState(() {
      _uploading = true;
      _status = 'Reading import file...';
    });

    try {
      final dir = await getExternalStorageDirectory();
      if (!mounted) return;
      if (dir == null) {
        throw Exception('External storage directory unavailable');
      }
      final file = File('${dir.path}/health_export.json');
      if (!await file.exists()) {
        if (!mounted) return;
        setState(() {
          _uploading = false;
          _status = 'No import file at:\n${file.path}\n\n'
              'Push one via adb:\n'
              'adb push health_export.json ${file.path}';
        });
        return;
      }

      final raw = await file.readAsString();
      if (!mounted) return;
      final payload = jsonDecode(raw) as Map<String, dynamic>;

      // Request WRITE permission for what we plan to write. Lives in the
      // debug manifest only — release builds can't even ask for these.
      const writeTypes = <HealthDataType>[
        HealthDataType.HEART_RATE,
        HealthDataType.STEPS,
        HealthDataType.DISTANCE_DELTA,
        HealthDataType.ACTIVE_ENERGY_BURNED,
        HealthDataType.TOTAL_CALORIES_BURNED,
        HealthDataType.SLEEP_SESSION,
        HealthDataType.WORKOUT,
      ];
      setState(() => _status = 'Requesting WRITE permissions...');
      final writeOk = await _health.requestAuthorization(
        writeTypes,
        permissions:
            writeTypes.map((_) => HealthDataAccess.WRITE).toList(),
      );
      if (!mounted) return;
      if (!writeOk) {
        setState(() {
          _uploading = false;
          _status = 'WRITE permission denied. Grant in Health Connect and retry.';
        });
        return;
      }

      // ---- Workouts ----
      final workouts =
          (payload['workouts'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      int workoutsOk = 0;
      for (var i = 0; i < workouts.length; i++) {
        final w = workouts[i];
        setState(() => _status =
            'Importing workout ${i + 1}/${workouts.length}...');
        try {
          final ok = await _health.writeWorkoutData(
            activityType: _parseWorkoutActivity(w['activity_type'] as String?),
            start: DateTime.parse(w['start_time'] as String),
            end: DateTime.parse(w['end_time'] as String),
            totalDistance: w['total_distance_meters'] as int?,
            totalDistanceUnit: HealthDataUnit.METER,
            totalEnergyBurned: w['total_energy_kcal'] as int?,
            totalEnergyBurnedUnit: HealthDataUnit.KILOCALORIE,
            title: w['source_app'] as String?,
          );
          if (ok) workoutsOk++;
        } catch (e) {
          debugPrint('[import] workout write failed: $e');
        }
        if (!mounted) return;
      }

      // ---- Numeric streams we can write ----
      const numericWritable = <String, HealthDataType>{
        'heart_rate_samples': HealthDataType.HEART_RATE,
      };
      int numericOk = 0;
      int numericTotal = 0;
      for (final entry in numericWritable.entries) {
        final samples = (payload[entry.key] as List?)
                ?.cast<Map<String, dynamic>>() ??
            [];
        numericTotal += samples.length;
        for (var i = 0; i < samples.length; i++) {
          if (i % 200 == 0) {
            setState(() => _status =
                'Importing ${entry.key} ${i + 1}/${samples.length}...');
            if (!mounted) return;
          }
          final s = samples[i];
          try {
            final ok = await _health.writeHealthData(
              value: (s['value'] as num).toDouble(),
              type: entry.value,
              startTime: DateTime.parse(s['time'] as String),
            );
            if (ok) numericOk++;
          } catch (e) {
            debugPrint('[import] ${entry.key} write failed: $e');
          }
        }
      }

      // ---- Interval streams we can write ----
      const intervalWritable = <String, HealthDataType>{
        'step_samples': HealthDataType.STEPS,
        'distance_samples': HealthDataType.DISTANCE_DELTA,
        'total_calorie_samples': HealthDataType.TOTAL_CALORIES_BURNED,
        'active_energy_samples': HealthDataType.ACTIVE_ENERGY_BURNED,
        'sleep_sessions': HealthDataType.SLEEP_SESSION,
      };
      int intervalOk = 0;
      int intervalTotal = 0;
      for (final entry in intervalWritable.entries) {
        final samples = (payload[entry.key] as List?)
                ?.cast<Map<String, dynamic>>() ??
            [];
        intervalTotal += samples.length;
        for (var i = 0; i < samples.length; i++) {
          if (i % 100 == 0) {
            setState(() => _status =
                'Importing ${entry.key} ${i + 1}/${samples.length}...');
            if (!mounted) return;
          }
          final s = samples[i];
          try {
            final ok = await _health.writeHealthData(
              value: (s['value'] as num).toDouble(),
              type: entry.value,
              startTime: DateTime.parse(s['start'] as String),
              endTime: DateTime.parse(s['end'] as String),
            );
            if (ok) intervalOk++;
          } catch (e) {
            debugPrint('[import] ${entry.key} write failed: $e');
          }
        }
      }

      // Note what got skipped so it's obvious in the result.
      const skippedKeys = [
        'hrv_rmssd_samples',
        'resting_heart_rate_samples',
        'respiratory_rate_samples',
        'sleep_deep_samples',
        'sleep_rem_samples',
        'sleep_light_samples',
        'sleep_awake_samples',
      ];
      int skippedCount = 0;
      for (final k in skippedKeys) {
        final n = (payload[k] as List?)?.length ?? 0;
        skippedCount += n;
        if (n > 0) {
          debugPrint('[import] skipped $n $k (no write API)');
        }
      }

      if (!mounted) return;
      setState(() {
        _uploading = false;
        _status = 'Import complete:\n'
            '  workouts: $workoutsOk/${workouts.length}\n'
            '  HR: $numericOk/$numericTotal\n'
            '  intervals: $intervalOk/$intervalTotal\n'
            '  skipped (no write API): $skippedCount';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _status = 'Import error: $e';
      });
    }
  }

  HealthWorkoutActivityType _parseWorkoutActivity(String? name) {
    if (name == null) return HealthWorkoutActivityType.OTHER;
    for (final t in HealthWorkoutActivityType.values) {
      if (t.name == name) return t;
    }
    return HealthWorkoutActivityType.OTHER;
  }

  // ============================================================
  // DEBUG ONLY — Trigger Health Connect's WRITE-permission dialog
  // without running an import. Lets you grant writes upfront on an
  // emulator before kicking off a multi-hour import. Permissions
  // requested here are the same set the import will need.
  // ============================================================
  static const List<HealthDataType> _writeTypes = [
    HealthDataType.HEART_RATE,
    HealthDataType.STEPS,
    HealthDataType.DISTANCE_DELTA,
    HealthDataType.ACTIVE_ENERGY_BURNED,
    HealthDataType.TOTAL_CALORIES_BURNED,
    HealthDataType.SLEEP_SESSION,
    HealthDataType.WORKOUT,
  ];

  Future<void> _requestWritePermissions() async {
    setState(() => _status = 'Requesting WRITE permissions...');
    try {
      final ok = await _health.requestAuthorization(
        _writeTypes,
        permissions:
            _writeTypes.map((_) => HealthDataAccess.WRITE).toList(),
      );
      if (!mounted) return;
      setState(() {
        _status = ok
            ? 'WRITE permissions granted. Safe to tap Import from File.'
            : 'WRITE permissions denied. Open Health Connect settings to grant.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = 'WRITE permission error: $e';
      });
    }
  }

  Map<String, dynamic> _numericSample(HealthDataPoint p) {
    final v = p.value;
    return {
      'uuid': p.uuid,
      'time': p.dateFrom.toUtc().toIso8601String(),
      'value': v is NumericHealthValue ? v.numericValue : null,
      'unit': p.unit.name,
      'source': p.sourceName,
      'recording_method': p.recordingMethod.name,
    };
  }

  Map<String, dynamic> _intervalSample(HealthDataPoint p) {
    final v = p.value;
    return {
      'uuid': p.uuid,
      'start': p.dateFrom.toUtc().toIso8601String(),
      'end': p.dateTo.toUtc().toIso8601String(),
      'value': v is NumericHealthValue ? v.numericValue : null,
      'unit': p.unit.name,
      'source': p.sourceName,
      'recording_method': p.recordingMethod.name,
    };
  }

  Future<List<HealthDataPoint>> _safeRead(
      HealthDataType t, DateTime start, DateTime end) async {
    try {
      return await _health.getHealthDataFromTypes(
        types: [t],
        startTime: start,
        endTime: end,
      );
    } catch (e, st) {
      // Don't crash the caller — expected for unpermissioned types — but
      // log so it's still visible in the dev console.
      debugPrint('[_safeRead] ${t.name} failed: $e\n$st');
      return [];
    }
  }

  // Streams uploaded in full across the entire sync window — independent of
  // any workout container. The server detects exercise sessions from the
  // raw HR + step traces, so we need everything inside the window regardless
  // of whether Fitbit wrapped it in an ExerciseSessionRecord.
  //
  // Every type in these maps MUST be in `_types` (and the manifest must
  // declare the matching READ_* permission), or the read returns empty.
  static const Map<String, HealthDataType> _numericStreams = {
    'heart_rate_samples': HealthDataType.HEART_RATE,
    'hrv_rmssd_samples': HealthDataType.HEART_RATE_VARIABILITY_RMSSD,
    'resting_heart_rate_samples': HealthDataType.RESTING_HEART_RATE,
    'respiratory_rate_samples': HealthDataType.RESPIRATORY_RATE,
  };

  static const Map<String, HealthDataType> _intervalStreams = {
    'step_samples': HealthDataType.STEPS,
    'distance_samples': HealthDataType.DISTANCE_DELTA,
    'total_calorie_samples': HealthDataType.TOTAL_CALORIES_BURNED,
    'active_energy_samples': HealthDataType.ACTIVE_ENERGY_BURNED,
    'sleep_sessions': HealthDataType.SLEEP_SESSION,
    'sleep_deep_samples': HealthDataType.SLEEP_DEEP,
    'sleep_rem_samples': HealthDataType.SLEEP_REM,
    'sleep_light_samples': HealthDataType.SLEEP_LIGHT,
    'sleep_awake_samples': HealthDataType.SLEEP_AWAKE,
  };

  /// Reads workouts + every configured stream over [windowStart, now] and
  /// assembles the `health_sync` payload. Shared by sync and export so the
  /// two can't drift (a past divergence here caused an OOM). Updates `_status`
  /// per stream; [labelSuffix] distinguishes the caller in that text.
  ///
  /// Reads one stream per query on purpose — batching all types into a single
  /// getHealthDataFromTypes call makes the health plugin serialize the whole
  /// result across the method channel in one allocation, and a full window of
  /// ~165k HR samples OOMs the Java heap.
  Future<({Map<String, dynamic> payload, int totalSamples, DateTime? maxSampleTime})>
      _buildSyncPayload(DateTime windowStart, DateTime now,
          {String labelSuffix = ''}) async {
    // Newest dateTo across everything we read — becomes the sync watermark.
    DateTime? maxSampleTime;
    void trackMax(DateTime t) {
      if (maxSampleTime == null || t.isAfter(maxSampleTime!)) {
        maxSampleTime = t;
      }
    }

    // Workouts use the package's special WORKOUT path (it aggregates
    // distance/calories/steps from related records). Separate read.
    final workouts = await _safeRead(HealthDataType.WORKOUT, windowStart, now);
    for (final w in workouts) {
      trackMax(w.dateTo);
    }

    final workoutPayloads = workouts.map((w) {
      final wv =
          w.value is WorkoutHealthValue ? w.value as WorkoutHealthValue : null;
      return <String, dynamic>{
        'source_uuid': w.uuid,
        'source_app': w.sourceName,
        'source_device_id': w.sourceDeviceId,
        'activity_type': wv?.workoutActivityType.name ?? 'OTHER',
        'recording_method': w.recordingMethod.name,
        'start_time': w.dateFrom.toUtc().toIso8601String(),
        'end_time': w.dateTo.toUtc().toIso8601String(),
        'duration_seconds': w.dateTo.difference(w.dateFrom).inSeconds,
        'total_distance_meters': wv?.totalDistance,
        'total_energy_kcal': wv?.totalEnergyBurned,
        'total_steps': wv?.totalSteps,
      };
    }).toList();

    final payload = <String, dynamic>{
      'type': 'health_sync',
      'athlete_id': _athleteId,
      'client_version': _clientVersion,
      'uploaded_at': now.toUtc().toIso8601String(),
      'source_platform': 'googleHealthConnect',
      'window_start': windowStart.toUtc().toIso8601String(),
      'window_end': now.toUtc().toIso8601String(),
      'workouts': workoutPayloads,
    };

    var totalSamples = 0;
    for (final e in _numericStreams.entries) {
      if (mounted) setState(() => _status = 'Reading ${e.key}$labelSuffix...');
      final samples = await _safeRead(e.value, windowStart, now);
      for (final s in samples) {
        trackMax(s.dateTo);
      }
      payload[e.key] = samples.map(_numericSample).toList();
      totalSamples += samples.length;
    }
    for (final e in _intervalStreams.entries) {
      if (mounted) setState(() => _status = 'Reading ${e.key}$labelSuffix...');
      final samples = await _safeRead(e.value, windowStart, now);
      for (final s in samples) {
        trackMax(s.dateTo);
      }
      payload[e.key] = samples.map(_intervalSample).toList();
      totalSamples += samples.length;
    }

    return (
      payload: payload,
      totalSamples: totalSamples,
      maxSampleTime: maxSampleTime,
    );
  }

  Future<void> _syncHealthData() async {
    setState(() {
      _uploading = true;
      _status = 'Reading data from Health Connect...';
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      final lastSyncIso = prefs.getString(_lastSyncPrefsKey);
      final now = DateTime.now();
      final windowStart = lastSyncIso != null
          ? DateTime.parse(lastSyncIso).subtract(_watermarkOverlap)
          : now.subtract(_firstSyncWindow);
      final windowDays = now.difference(windowStart).inMinutes / (60 * 24);
      final windowLabel = lastSyncIso != null
          ? 'since last sync (${windowDays.toStringAsFixed(1)} days)'
          : 'full ${_firstSyncWindow.inDays}-day window (first sync)';

      final built = await _buildSyncPayload(windowStart, now);
      if (!mounted) return;
      final payload = built.payload;
      final totalSamples = built.totalSamples;
      final maxSampleTime = built.maxSampleTime;
      final workoutCount = (payload['workouts'] as List).length;

      final bodyBytes = utf8.encode(jsonEncode(payload));
      final sizeMB = (bodyBytes.length / 1024 / 1024).toStringAsFixed(2);
      setState(() => _status =
          'Uploading $workoutCount workouts + $totalSamples samples ($sizeMB MB)...');

      final response = await http
          .post(
            Uri.parse('$_serverBase/workouts'),
            headers: {
              'Content-Type': 'application/json',
              ..._auth.authHeaders,
            },
            body: bodyBytes,
          )
          .timeout(const Duration(seconds: 120));
      if (!mounted) return;

      final ok = response.statusCode >= 200 && response.statusCode < 300;
      if (ok && maxSampleTime != null) {
        // Only advance the watermark on a successful 2xx AND when we
        // actually uploaded something. If the sync was empty, leave the
        // watermark alone so the next sync re-queries the same window —
        // that way delayed Health Connect inserts can still be picked up.
        await prefs.setString(
            _lastSyncPrefsKey, maxSampleTime.toUtc().toIso8601String());
        if (!mounted) return;
      }

      // 401 → token rejected. Drop it so the next sync attempt forces
      // sign-in, and show the auth card again instead of a noisy error.
      if (response.statusCode == 401) {
        await _auth.invalidate();
        if (!mounted) return;
        setState(() {
          _uploading = false;
          _status =
              'Sign-in expired. Please sign in again, then re-tap Sync.';
        });
        return;
      }

      setState(() {
        _uploading = false;
        if (ok) {
          _status =
              'Synced $sizeMB MB ($windowLabel): $workoutCount workouts, $totalSamples samples. Server: ${response.statusCode}.';
        } else {
          _status = 'Upload failed: ${response.statusCode}\n${response.body}';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _status = 'Sync error: $e';
      });
    }
  }

  Future<void> _readHeartRate() async {
    setState(() => _status = 'Reading heart rate data...');

    try {
      final now = DateTime.now();
      final yesterday = now.subtract(const Duration(days: 1));

      final data = await _health.getHealthDataFromTypes(
        types: [HealthDataType.HEART_RATE],
        startTime: yesterday,
        endTime: now,
      );
      if (!mounted) return;

      if (data.isEmpty) {
        setState(() {
          _status = 'No heart rate data found in the last 24 hours.';
          _heartRateValue = null;
          _heartRateTime = null;
        });
        return;
      }

      data.sort((a, b) => b.dateFrom.compareTo(a.dateFrom));
      final latest = data.first;
      final v = latest.value;
      final bpm = v is NumericHealthValue ? v.numericValue : v;

      setState(() {
        _heartRateValue = '$bpm BPM';
        _heartRateTime = latest.dateFrom.toLocal().toString().substring(0, 19);
        _status =
            'Heart rate data loaded (${data.length} readings in last 24h).';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = 'Error reading heart rate: $e';
        _heartRateValue = null;
        _heartRateTime = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Page 0 = production Home. Page 1 = Debug tools (debug builds only).
    final pages = <Widget>[
      _buildHomePage(theme),
      if (kDebugMode) _buildDebugPage(theme),
    ];
    final index = _pageIndex.clamp(0, pages.length - 1);

    return Scaffold(
      appBar: AppBar(
        title: Text(index == 0 ? 'XC Training Data' : 'Debug Tools'),
        centerTitle: true,
      ),
      body: pages[index],
      // Only show the nav bar when there's more than one page (i.e. debug).
      bottomNavigationBar: pages.length < 2
          ? null
          : NavigationBar(
              selectedIndex: index,
              onDestinationSelected: (i) => setState(() => _pageIndex = i),
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.home_outlined),
                  selectedIcon: Icon(Icons.home),
                  label: 'Home',
                ),
                NavigationDestination(
                  icon: Icon(Icons.bug_report_outlined),
                  selectedIcon: Icon(Icons.bug_report),
                  label: 'Debug',
                ),
              ],
            ),
    );
  }

  // Shared status card — shown on both pages so an action's result is
  // visible whichever tab you're on.
  Widget _buildStatusCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Status', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Text(_status),
          ],
        ),
      ),
    );
  }

  // GPS route recording card — independent of Health Connect permissions.
  Widget _buildRecordCard(ThemeData theme) {
    final km = (_distanceMeters / 1000).toStringAsFixed(2);
    return Card(
      color: _recording ? theme.colorScheme.tertiaryContainer : null,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.route),
                const SizedBox(width: 8),
                Text('Record Run (GPS)', style: theme.textTheme.titleSmall),
              ],
            ),
            if (_recording) ...[
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _recordStat(theme, _fmtDuration(_elapsed), 'time'),
                  _recordStat(theme, km, 'km'),
                  _recordStat(theme, '${_track.length}', 'points'),
                ],
              ),
            ],
            const SizedBox(height: 16),
            if (!_recording)
              FilledButton.icon(
                onPressed: _startRecording,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Start Run'),
              )
            else
              FilledButton.icon(
                onPressed: _stopRecording,
                style: FilledButton.styleFrom(
                  backgroundColor: theme.colorScheme.error,
                  foregroundColor: theme.colorScheme.onError,
                ),
                icon: const Icon(Icons.stop),
                label: const Text('Stop & Save'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _recordStat(ThemeData theme, String value, String label) {
    return Column(
      children: [
        Text(value,
            style: theme.textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.bold)),
        Text(label, style: theme.textTheme.bodySmall),
      ],
    );
  }

  Widget _buildHomePage(ThemeData theme) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildAuthCard(theme),
          const SizedBox(height: 16),
          _buildStatusCard(theme),
          const SizedBox(height: 16),
          _buildRecordCard(theme),
          const SizedBox(height: 16),
          if (!_permissionsGranted)
            FilledButton.icon(
              onPressed: _requestPermissions,
              icon: const Icon(Icons.lock_open),
              label: const Text('Request Permissions'),
            ),
          if (_permissionsGranted)
            FilledButton.tonal(
              onPressed: _uploading ? null : _readHeartRate,
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.favorite),
                  SizedBox(width: 8),
                  Text('Read My Heart Rate'),
                ],
              ),
            ),
          const SizedBox(height: 12),
          if (_permissionsGranted)
            FilledButton(
              onPressed:
                  (_uploading || !_auth.isSignedIn) ? null : _syncHealthData,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (_uploading)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  else
                    const Icon(Icons.cloud_upload),
                  const SizedBox(width: 8),
                  Text(_uploading
                      ? 'Uploading...'
                      : _auth.isSignedIn
                          ? 'Sync to Server'
                          : 'Sign in to sync'),
                ],
              ),
            ),
          const SizedBox(height: 24),
          if (_heartRateValue != null)
            Card(
              color: theme.colorScheme.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  children: [
                    Icon(
                      Icons.favorite,
                      size: 48,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _heartRateValue!,
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _heartRateTime!,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ============================================================
  // DEBUG ONLY — this whole page is built only when kDebugMode is
  // true. Remove the page (and its methods) before final ship.
  // ============================================================
  Widget _buildDebugPage(ThemeData theme) {
    final orange = Colors.orange.shade800;
    OutlinedButton debugButton(
        IconData icon, String label, VoidCallback onPressed) {
      return OutlinedButton.icon(
        onPressed: _uploading ? null : onPressed,
        icon: Icon(icon),
        label: Text(label),
        style: OutlinedButton.styleFrom(
          foregroundColor: orange,
          side: BorderSide(color: orange),
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildStatusCard(theme),
          const SizedBox(height: 16),
          if (!_permissionsGranted)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Text(
                  'Grant Health Connect permissions on the Home tab first — '
                  'the debug tools read and write health data.',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ),
          if (_permissionsGranted) ...[
            debugButton(
                Icons.search, 'Discover Workout Data', _discoverWorkoutData),
            const SizedBox(height: 8),
            debugButton(
                Icons.travel_explore, 'Scan All Data (30d)', _discoverAllData),
            const SizedBox(height: 8),
            debugButton(Icons.file_download, 'Export to File', _exportToFile),
            const SizedBox(height: 8),
            debugButton(Icons.edit, 'Request WRITE Permissions',
                _requestWritePermissions),
            const SizedBox(height: 8),
            debugButton(
                Icons.file_upload, 'Import from File', _importFromFile),
          ],
        ],
      ),
    );
  }
}
