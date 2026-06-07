import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:health/health.dart';
import 'package:http/http.dart' as http;

// Server URL. Use 10.0.2.2 from the Android emulator (its alias for the host
// machine's localhost), or the host's LAN IP from a physical phone. Change
// when you move to a real server / domain.
const String _serverUrl = 'http://10.0.0.23:8000/workouts';

// Identifies which runner's data this is. Hardcoded for now; eventually this
// will come from a login flow or device-side config.
const int _athleteId = 1;

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

  String _status = 'Initializing Health Connect...';
  bool _configured = false;
  bool _permissionsGranted = false;
  bool _uploading = false;
  String? _heartRateValue;
  String? _heartRateTime;

  final List<HealthDataType> _types = [
    HealthDataType.HEART_RATE,
    HealthDataType.STEPS,
    HealthDataType.DISTANCE_DELTA,
    HealthDataType.SLEEP_ASLEEP,
    HealthDataType.ACTIVE_ENERGY_BURNED,
    // TOTAL_CALORIES_BURNED is required even though we never directly read
    // it: the health package's WORKOUT reader internally queries
    // TotalCaloriesBurnedRecord to aggregate calories, and the read throws
    // SecurityException (returning an empty list) without this permission.
    HealthDataType.TOTAL_CALORIES_BURNED,
    HealthDataType.WORKOUT,
  ];

  // All types are READ-only. The debug "Insert Test Workout" button no longer
  // needs WRITE; if you re-enable it, switch HEART_RATE, DISTANCE_DELTA, and
  // WORKOUT back to READ_WRITE here (and grant WRITE in Health Connect).
  List<HealthDataAccess> get _permissions =>
      _types.map((_) => HealthDataAccess.READ).toList();

  @override
  void initState() {
    super.initState();
    _configureHealth();
  }

  Future<void> _configureHealth() async {
    try {
      await _health.configure();
      _configured = true;
      await _checkPermissions();
    } catch (e) {
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

      setState(() {
        _permissionsGranted = hasPermissions ?? false;
        _status = _permissionsGranted
            ? 'Permissions granted. Ready to read data!'
            : 'Tap "Request Permissions" to get started.';
      });
    } catch (e) {
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

      setState(() {
        _permissionsGranted = requested;
        _status = requested
            ? 'Permissions granted!'
            : 'Permissions denied. Open Health Connect settings to grant access.';
      });
    } catch (e) {
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
    setState(() => _status = 'Discovering — watch the console output...');

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

      if (workouts.isEmpty) {
        debugPrint('[DISCOVERY] No workouts found in last 90 days.');
        setState(() => _status = 'No workouts found. See console.');
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

      setState(() => _status =
          'Discovery complete: ${recent.length} workout(s) dumped. Check console.');
    } catch (e) {
      setState(() => _status = 'Discovery error: $e');
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
    setState(() => _status =
        'Scanning 30 days of all data types — watch console...');

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

      final nonEmpty = results.entries.where((e) => e.value.isNotEmpty).length;
      setState(() => _status =
          'Scan complete: $nonEmpty/${allTypes.length} types had data. Check console.');
    } catch (e) {
      setState(() => _status = 'Scan error: $e');
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
    } catch (_) {
      return [];
    }
  }

  // Streams uploaded in full across the entire sync window — independent of
  // any workout container. The server detects exercise sessions from the
  // raw HR + step traces, so we need everything inside the window regardless
  // of whether Fitbit wrapped it in an ExerciseSessionRecord.
  static const Map<String, HealthDataType> _numericStreams = {
    'heart_rate_samples': HealthDataType.HEART_RATE,
    'speed_samples': HealthDataType.SPEED,
    'hrv_rmssd_samples': HealthDataType.HEART_RATE_VARIABILITY_RMSSD,
    'resting_heart_rate_samples': HealthDataType.RESTING_HEART_RATE,
    'respiratory_rate_samples': HealthDataType.RESPIRATORY_RATE,
    'blood_oxygen_samples': HealthDataType.BLOOD_OXYGEN,
    'skin_temperature_samples': HealthDataType.SKIN_TEMPERATURE,
    'body_temperature_samples': HealthDataType.BODY_TEMPERATURE,
  };

  static const Map<String, HealthDataType> _intervalStreams = {
    'step_samples': HealthDataType.STEPS,
    'distance_samples': HealthDataType.DISTANCE_DELTA,
    'total_calorie_samples': HealthDataType.TOTAL_CALORIES_BURNED,
    'active_energy_samples': HealthDataType.ACTIVE_ENERGY_BURNED,
    'basal_energy_samples': HealthDataType.BASAL_ENERGY_BURNED,
    'flights_climbed_samples': HealthDataType.FLIGHTS_CLIMBED,
    'activity_intensity_samples': HealthDataType.ACTIVITY_INTENSITY,
    'sleep_sessions': HealthDataType.SLEEP_SESSION,
    'sleep_deep_samples': HealthDataType.SLEEP_DEEP,
    'sleep_rem_samples': HealthDataType.SLEEP_REM,
    'sleep_light_samples': HealthDataType.SLEEP_LIGHT,
    'sleep_awake_samples': HealthDataType.SLEEP_AWAKE,
  };

  Future<void> _uploadWorkouts() async {
    setState(() {
      _uploading = true;
      _status = 'Reading 30 days of data from Health Connect...';
    });

    try {
      final now = DateTime.now();
      final windowStart = now.subtract(const Duration(days: 30));

      // Read workouts (they're useful as ground truth when Fitbit DOES
      // wrap activity in ExerciseSessionRecord; server uses them and the
      // raw streams together).
      final workouts = await _safeRead(
          HealthDataType.WORKOUT, windowStart, now);

      final workoutPayloads = workouts.map((w) {
        final v = w.value;
        return <String, dynamic>{
          'source_uuid': w.uuid,
          'source_app': w.sourceName,
          'source_device_id': w.sourceDeviceId,
          'activity_type': v is WorkoutHealthValue
              ? v.workoutActivityType.name
              : 'OTHER',
          'recording_method': w.recordingMethod.name,
          'start_time': w.dateFrom.toUtc().toIso8601String(),
          'end_time': w.dateTo.toUtc().toIso8601String(),
          'duration_seconds': w.dateTo.difference(w.dateFrom).inSeconds,
          'total_distance_meters':
              v is WorkoutHealthValue ? v.totalDistance : null,
          'total_energy_kcal':
              v is WorkoutHealthValue ? v.totalEnergyBurned : null,
          'total_steps': v is WorkoutHealthValue ? v.totalSteps : null,
        };
      }).toList();

      // Pull every relevant raw stream across the whole window.
      final payload = <String, dynamic>{
        'type': 'health_sync',
        'athlete_id': _athleteId,
        'client_version': '1.0.0+1',
        'uploaded_at': now.toUtc().toIso8601String(),
        'source_platform': 'googleHealthConnect',
        'window_start': windowStart.toUtc().toIso8601String(),
        'window_end': now.toUtc().toIso8601String(),
        'workouts': workoutPayloads,
      };

      int totalSamples = 0;
      for (final e in _numericStreams.entries) {
        setState(() => _status = 'Reading ${e.key}...');
        final samples = await _safeRead(e.value, windowStart, now);
        payload[e.key] = samples.map(_numericSample).toList();
        totalSamples += samples.length;
      }
      for (final e in _intervalStreams.entries) {
        setState(() => _status = 'Reading ${e.key}...');
        final samples = await _safeRead(e.value, windowStart, now);
        payload[e.key] = samples.map(_intervalSample).toList();
        totalSamples += samples.length;
      }

      final bodyBytes = utf8.encode(jsonEncode(payload));
      final sizeMB = (bodyBytes.length / 1024 / 1024).toStringAsFixed(2);
      setState(() => _status =
          'Uploading ${workouts.length} workouts + $totalSamples samples ($sizeMB MB)...');

      final response = await http
          .post(
            Uri.parse(_serverUrl),
            headers: {'Content-Type': 'application/json'},
            body: bodyBytes,
          )
          .timeout(const Duration(seconds: 120));

      setState(() {
        _uploading = false;
        if (response.statusCode >= 200 && response.statusCode < 300) {
          _status =
              'Synced $sizeMB MB (${workouts.length} workouts, $totalSamples samples). Server: ${response.statusCode}.';
        } else {
          _status =
              'Upload failed: ${response.statusCode}\n${response.body}';
        }
      });
    } catch (e) {
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

      setState(() {
        _heartRateValue = '${latest.value} BPM';
        _heartRateTime = latest.dateFrom.toLocal().toString().substring(0, 19);
        _status =
            'Heart rate data loaded (${data.length} readings in last 24h).';
      });
    } catch (e) {
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

    return Scaffold(
      appBar: AppBar(
        title: const Text('XC Training Data'),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
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
            ),
            const SizedBox(height: 16),
            if (!_permissionsGranted)
              FilledButton.icon(
                onPressed: _requestPermissions,
                icon: const Icon(Icons.lock_open),
                label: const Text('Request Permissions'),
              ),
            if (_permissionsGranted)
              FilledButton.tonal(
                onPressed: _readHeartRate,
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
                onPressed: _uploading ? null : _uploadWorkouts,
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
                    Text(_uploading ? 'Uploading...' : 'Sync Workouts to Server'),
                  ],
                ),
              ),
            const SizedBox(height: 24),
            // ============================================================
            // DEBUG ONLY — remove this whole section before shipping.
            // ============================================================
            if (_permissionsGranted)
              Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.orange, width: 2),
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.bug_report, color: Colors.orange.shade800),
                        const SizedBox(width: 6),
                        Text(
                          'DEBUG ONLY',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: Colors.orange.shade800,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _discoverWorkoutData,
                      icon: const Icon(Icons.search),
                      label: const Text('Discover Workout Data'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.orange.shade800,
                        side: BorderSide(color: Colors.orange.shade800),
                      ),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _discoverAllData,
                      icon: const Icon(Icons.travel_explore),
                      label: const Text('Scan All Data (30d)'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.orange.shade800,
                        side: BorderSide(color: Colors.orange.shade800),
                      ),
                    ),
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
      ),
    );
  }
}
