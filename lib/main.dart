import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
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

// When the server has no data for this athlete yet, the first sync uploads
// this much history. Afterwards each sync asks the server for the newest
// sample it has (GET /me/last-sample-time) and uploads from there — the
// server is the single source of truth, so reinstalls and second devices
// resume where the data actually ends.
const Duration _firstSyncWindow = Duration(hours: 24);

// How far back the Runs tab and the debug export look. Deliberately wider
// than the first-sync upload window — showing a month of history is useful
// even though uploads default to the last day.
const Duration _historyWindow = Duration(days: 30);

// shared_preferences key — Health Connect route ids (workout uuid) already
// uploaded to the server, so Sync only sends new ones.
const String _uploadedHcRoutesPrefsKey = 'uploaded_hc_routes';

// shared_preferences keys — onboarding state. route_access_done marks the
// route-consent step completed (granted or explicitly skipped); auto_sync
// stores the user's automatic-upload choice (absence = not asked yet, which
// keeps them in onboarding).
const String _routeAccessDonePrefsKey = 'route_access_done';
const String _autoSyncPrefsKey = 'auto_sync_enabled';

// shared_preferences key — iOS only: the health permission sheet has been
// shown and accepted. HealthKit never discloses READ-grant status (the
// plugin's hasPermissions returns null for reads), so without this flag every
// cold launch would treat permissions as missing and re-show onboarding.
const String _healthPermsRequestedPrefsKey = 'health_perms_requested';

// Re-query an overlap behind the watermark on every incremental sync, to catch
// late-arriving Health Connect samples. The watermark is a single global max
// across all streams, so live HR pins it near "now"; but Fitbit derives resting
// HR, HRV, and sleep from overnight data and delivers them hours late, with a
// dateTo well behind that global max. A 1h overlap missed them — use 24h so a
// late-delivered sample still falls inside the next sync's window. The server's
// UUID upsert dedup makes the wider re-query harmless.
const Duration _watermarkOverlap = Duration(hours: 24);

// Moving-average window for smoothing the *displayed* GPS path — tames the
// zigzag from GPS jitter. Raw points are kept intact; only the drawn polyline
// is smoothed. Higher = smoother but rounds corners more; 1 disables.
const int _pathSmoothingWindow = 7;

// Returns a smoothed copy of [pts] using a centered moving average. Endpoints
// are preserved (the window shrinks at the edges).
List<LatLng> smoothPath(List<LatLng> pts, {int window = _pathSmoothingWindow}) {
  if (pts.length <= 2 || window < 2) return pts;
  final half = window ~/ 2;
  final out = <LatLng>[];
  for (var i = 0; i < pts.length; i++) {
    var lat = 0.0, lng = 0.0, n = 0;
    for (var j = i - half; j <= i + half; j++) {
      if (j < 0 || j >= pts.length) continue;
      lat += pts[j].latitude;
      lng += pts[j].longitude;
      n++;
    }
    out.add(LatLng(lat / n, lng / n));
  }
  return out;
}

// One logical run assembled from Health Connect workouts. Multiple apps often
// write the SAME physical run (e.g. Fitbit records it with a route but types
// it OTHER; Strava imports it typed RUNNING but without a route), so workouts
// whose time windows overlap are grouped into one run for display.
class _HcRun {
  final List<HealthDataPoint> members = [];
  DateTime start;
  DateTime end;

  _HcRun(HealthDataPoint first) : start = first.dateFrom, end = first.dateTo {
    members.add(first);
  }

  void add(HealthDataPoint w) {
    members.add(w);
    if (w.dateFrom.isBefore(start)) start = w.dateFrom;
    if (w.dateTo.isAfter(end)) end = w.dateTo;
  }

  bool overlaps(HealthDataPoint w) =>
      w.dateFrom.isBefore(end) && w.dateTo.isAfter(start);

  Set<String> get uuids => {for (final m in members) m.uuid};

  Duration get duration => end.difference(start);

  // Best label across the group: any specific type beats OTHER.
  String get activityType {
    for (final m in members) {
      final v = m.value;
      if (v is WorkoutHealthValue && v.workoutActivityType.name != 'OTHER') {
        return v.workoutActivityType.name;
      }
    }
    return 'OTHER';
  }

  double? get distanceMeters {
    double? best;
    for (final m in members) {
      final v = m.value;
      final d = v is WorkoutHealthValue ? v.totalDistance?.toDouble() : null;
      if (d != null && (best == null || d > best)) best = d;
    }
    return best;
  }

  double? get energyKcal {
    double? best;
    for (final m in members) {
      final v = m.value;
      final e = v is WorkoutHealthValue
          ? v.totalEnergyBurned?.toDouble()
          : null;
      if (e != null && (best == null || e > best)) best = e;
    }
    return best;
  }

  int? get steps {
    int? best;
    for (final m in members) {
      final v = m.value;
      final s = v is WorkoutHealthValue ? v.totalSteps?.toInt() : null;
      if (s != null && (best == null || s > best)) best = s;
    }
    return best;
  }

  List<String> get sources {
    final seen = <String>{};
    return [
      for (final m in members)
        if (seen.add(m.sourceName)) m.sourceName,
    ];
  }
}

// The map itself: route polyline with start/end markers, framed to fit.
// Shown on the run detail page when the run has a GPS route.
class _RouteMapView extends StatelessWidget {
  final List<LatLng> points;

  const _RouteMapView(this.points);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FlutterMap(
      options: MapOptions(
        initialCenter: points.first,
        initialZoom: 16,
        initialCameraFit: points.length >= 2
            ? CameraFit.coordinates(
                coordinates: points,
                padding: const EdgeInsets.all(40),
              )
            : null,
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.github.briansp2020.xctraining',
        ),
        PolylineLayer(
          polylines: [
            Polyline(
              points: smoothPath(points),
              strokeWidth: 5,
              color: theme.colorScheme.primary,
            ),
          ],
        ),
        MarkerLayer(
          markers: [
            Marker(
              point: points.first,
              width: 16,
              height: 16,
              child: _dot(Colors.green),
            ),
            Marker(
              point: points.last,
              width: 16,
              height: 16,
              child: _dot(Colors.red),
            ),
          ],
        ),
      ],
    );
  }

  static Widget _dot(Color c) => Container(
    decoration: BoxDecoration(
      color: c,
      shape: BoxShape.circle,
      border: Border.all(color: Colors.white, width: 2),
    ),
  );
}

// One metric shown on the run detail page.
class _RunStat {
  final IconData icon;
  final String label;
  final String value;

  const _RunStat(this.icon, this.label, this.value);
}

// Detail view for a run recorded by another app: its health metrics, with the
// GPS route shown on top when one is available. When there's no route we simply
// show the metrics — no empty-map placeholder.
class _HcRunDetailPage extends StatelessWidget {
  final String title;
  final String subtitle;
  final List<_RunStat> stats;
  final List<LatLng>? points;
  final bool consentBlocked;

  const _HcRunDetailPage({
    required this.title,
    required this.subtitle,
    required this.stats,
    required this.points,
    required this.consentBlocked,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pts = points;
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(24),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(subtitle, style: theme.textTheme.bodySmall),
          ),
        ),
      ),
      body: ListView(
        children: [
          if (pts != null) SizedBox(height: 320, child: _RouteMapView(pts)),
          if (pts == null && consentBlocked)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Text(
                'This run has a route. Enable the "Exercise routes" permission '
                'in Health Connect to see it here.',
                style: theme.textTheme.bodySmall,
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [for (final s in stats) _statCard(theme, s)],
            ),
          ),
        ],
      ),
    );
  }

  static Widget _statCard(ThemeData theme, _RunStat s) => Container(
    width: 104,
    padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
    decoration: BoxDecoration(
      color: theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      children: [
        Icon(s.icon, size: 22, color: theme.colorScheme.primary),
        const SizedBox(height: 8),
        Text(
          s.value,
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          s.label,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    ),
  );
}

void main() {
  runApp(const XCTrainingApp());
}

class XCTrainingApp extends StatelessWidget {
  const XCTrainingApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Chadwick XC Training',
      theme: ThemeData(
        // Seeded from the team logo's sky blue (same value as the adaptive
        // launcher-icon background in pubspec.yaml).
        colorSchemeSeed: const Color(0xFF81C6F0),
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
  // Native bridge for Health Connect's route-consent dialogs (MainActivity.kt).
  // The health plugin can't request route access — see _grantRouteAccess.
  static const MethodChannel _routeAccess = MethodChannel(
    'xctraining/route_access',
  );

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
  // Last sign-in failure, shown on the welcome screen (which doesn't display
  // the general _status text).
  String? _signInError;

  // Onboarding state, persisted in prefs. Onboarding is complete when health
  // permissions are granted, the route-access step is done (or skipped), and
  // the user has made an automatic-upload choice.
  bool _routeAccessDone = false;
  bool? _autoSyncEnabled; // null = not asked yet
  bool get _onboarded =>
      _permissionsGranted && _routeAccessDone && _autoSyncEnabled != null;

  // Home-page upload status: samples in the core streams newer than the
  // server's watermark. null = check in progress; -1 = never synced;
  // -2 = server unreachable.
  int? _pendingSamples;
  DateTime? _lastSyncAt;

  // Cached future for the Runs tab: workouts other apps wrote to Health
  // Connect, grouped into logical runs. Refreshed when the tab is opened.
  Future<List<_HcRun>>? _hcRunsFuture;

  // Bottom-nav page index. Release: 0 = Home, 1 = Runs. Debug builds add
  // 2 = Debug tools.
  int _pageIndex = 0;

  // Single source of truth for what the sync reads + what we request permission
  // for. Must match the manifest's READ_* declarations and the union of
  // _numericStreams + _intervalStreams + [WORKOUT].
  final List<HealthDataType> _types = [
    // Core training signals
    HealthDataType.HEART_RATE,
    HealthDataType.STEPS,
    HealthDataType.DISTANCE_DELTA,
    // GPS routes attached to other apps' workouts (Fitbit / Pixel Watch runs).
    // Must be requested together with WORKOUT. Reading routes OTHER apps wrote
    // additionally needs "Exercise routes → Always allow" in Health Connect's
    // app permissions; until granted they read back empty (ConsentRequired).
    HealthDataType.WORKOUT_ROUTE,
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
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _authLoading = false;
      // HealthKit grants workout-route reading through the standard health
      // permission — there's no separate route consent like Health Connect's,
      // and the xctraining/route_access channel is Android-only. So on iOS the
      // route step is always satisfied; skip it.
      _routeAccessDone =
          Platform.isIOS || (prefs.getBool(_routeAccessDonePrefsKey) ?? false);
      _autoSyncEnabled = prefs.containsKey(_autoSyncPrefsKey)
          ? prefs.getBool(_autoSyncPrefsKey)
          : null;
    });
    await _configureHealth();
    if (!mounted) return;
    if (_auth.isSignedIn) _afterSignedIn();
  }

  // Post-sign-in kick-off, shared by app start and the sign-in buttons: if
  // the user is fully onboarded, either auto-upload (their choice) or just
  // refresh the "anything new to upload?" home status.
  void _afterSignedIn() {
    if (!_onboarded) return; // onboarding UI takes over
    if (_autoSyncEnabled == true && !_uploading) {
      _syncHealthData(); // calls _refreshPendingData when done
    } else {
      _refreshPendingData();
    }
  }

  // Asks the server for the newest sample timestamp it has for this athlete
  // (GET /me/last-sample-time) — the sync watermark. Returns null when the
  // server has no data yet (first sync, or right after a data reset). Throws
  // on any failure; a 401 also drops the token so the sign-in card returns.
  Future<DateTime?> _fetchServerWatermark() async {
    final resp = await http
        .get(
          Uri.parse('$_serverBase/me/last-sample-time'),
          headers: _auth.authHeaders,
        )
        .timeout(const Duration(seconds: 30));
    if (resp.statusCode == 401) {
      await _auth.invalidate();
      throw Exception('Sign-in expired. Please sign in again.');
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('Server returned ${resp.statusCode}');
    }
    final t =
        (jsonDecode(resp.body) as Map<String, dynamic>)['last_sample_time'];
    return t == null ? null : DateTime.parse(t as String).toLocal();
  }

  // Recomputes the home page's upload status: how many samples in the core
  // streams are newer than the server's watermark. HR trickles in
  // continuously, so any nonzero count shows the Sync button.
  Future<void> _refreshPendingData() async {
    if (!_onboarded || !_auth.isSignedIn) return;
    setState(() => _pendingSamples = null); // check in progress
    final DateTime? last;
    try {
      last = await _fetchServerWatermark();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _pendingSamples = -2; // server unreachable
        _lastSyncAt = null;
        _status = 'Could not check the server: $e';
      });
      return;
    }
    if (!mounted) return;
    if (last == null) {
      setState(() {
        _pendingSamples = -1; // never synced
        _lastSyncAt = null;
      });
      return;
    }
    final now = DateTime.now();
    var count = 0;
    for (final t in [
      HealthDataType.WORKOUT,
      HealthDataType.HEART_RATE,
      HealthDataType.STEPS,
    ]) {
      count += (await _safeRead(t, last, now)).length;
      if (!mounted) return;
    }
    setState(() {
      _pendingSamples = count;
      _lastSyncAt = last!.toLocal();
    });
  }

  // Records the user's automatic-upload choice (the final onboarding step,
  // also togglable from the home page).
  Future<void> _setAutoSync(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoSyncPrefsKey, enabled);
    if (!mounted) return;
    final firstDecision = _autoSyncEnabled == null;
    setState(() => _autoSyncEnabled = enabled);
    if (firstDecision && enabled && !_uploading) {
      _syncHealthData(); // onboarding just finished — start the first upload
    } else {
      _refreshPendingData();
    }
  }

  String _fmtDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  Future<void> _signInWithGoogle() async {
    setState(() {
      _status = 'Signing in with Google...';
      _signInError = null;
    });
    final err = await _auth.signInWithGoogle();
    if (!mounted) return;
    setState(() {
      _signInError = err;
      _status =
          err ?? 'Signed in as ${_auth.email ?? _auth.name ?? "(unknown)"}.';
    });
    if (err == null) _afterSignedIn();
  }

  Future<void> _signInWithDevEmail() async {
    final controller = TextEditingController(text: _auth.email ?? '');
    final String? email;
    try {
      email = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Dev sign-in'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Email to sign in as. The server must be running '
                'with DEV_MODE=true for this to work.',
              ),
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
    } finally {
      controller.dispose();
    }
    if (email == null || email.trim().isEmpty) return;
    if (!mounted) return;
    setState(() {
      _status = 'Signing in as $email...';
      _signInError = null;
    });
    final err = await _auth.signInWithDevEmail(email);
    if (!mounted) return;
    setState(() {
      _signInError = err;
      _status = err ?? 'Signed in as ${_auth.email ?? email}.';
    });
    if (err == null) _afterSignedIn();
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
              Icon(
                Icons.account_circle,
                color: theme.colorScheme.onSecondaryContainer,
              ),
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
              TextButton(onPressed: _signOut, child: const Text('Sign out')),
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
              onPressed: _auth.isGoogleConfigured ? _signInWithGoogle : null,
              icon: const Icon(Icons.login),
              label: Text(
                _auth.isGoogleConfigured
                    ? 'Sign in with Google'
                    : 'Google Sign-In not configured',
              ),
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
      // HealthKit never discloses READ-grant status, so on iOS hasPermissions
      // is always null for our read-only types. Fall back to "the permission
      // sheet was accepted once" persisted at request time — otherwise every
      // cold launch re-shows onboarding.
      var granted = hasPermissions ?? false;
      if (!granted && Platform.isIOS) {
        final prefs = await SharedPreferences.getInstance();
        granted = prefs.getBool(_healthPermsRequestedPrefsKey) ?? false;
      }
      if (!mounted) return;

      setState(() {
        _permissionsGranted = granted;
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
      if (requested && Platform.isIOS) {
        // Remember the grant — hasPermissions can't detect it on iOS (see
        // _checkPermissions).
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_healthPermsRequestedPrefsKey, true);
      }
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
        '[DISCOVERY] Found ${workouts.length} workouts; inspecting ${recent.length} most recent.',
      );

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
          '\nProbing related data types in window [${w.dateFrom.toIso8601String()} .. ${w.dateTo.toIso8601String()}]:',
        );

        for (final t in probeTypes) {
          try {
            final samples = await _health.getHealthDataFromTypes(
              types: [t],
              startTime: w.dateFrom,
              endTime: w.dateTo,
            );
            if (samples.isEmpty) {
              debugPrint(
                '  ${t.name}: 0 samples (no data, or permission missing)',
              );
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
                '    ...${samples.length - 1} additional sample(s) elided',
              );
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
        '[ALL DATA] 30-day window: ${thirtyDaysAgo.toIso8601String()} -> ${now.toIso8601String()}',
      );
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
          '${entry.key.name.padRight(36)} ${samples.length.toString().padLeft(5)}   $sourceStr',
        );
      }

      debugPrint('\n\nFirst sample of each non-empty type:');
      for (final entry in results.entries) {
        if (entry.value.isEmpty) continue;
        debugPrint(
          '\n--- ${entry.key.name} (${entry.value.length} samples) ---',
        );
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
          final count = v is NumericHealthValue
              ? v.numericValue.toDouble()
              : 0.0;
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
            '(${entry.key.toStringAsFixed(1)} spm)  ${s.sourceName}',
          );
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
      _status = 'Reading ${_historyWindow.inDays} days for export...';
    });

    try {
      final now = DateTime.now();
      final windowStart = now.subtract(_historyWindow);

      final built = await _buildSyncPayload(
        windowStart,
        now,
        labelSuffix: ' (export)',
      );
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
        _status =
            'Exported $sizeMB MB '
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
          _status =
              'No import file at:\n${file.path}\n\n'
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
        permissions: writeTypes.map((_) => HealthDataAccess.WRITE).toList(),
      );
      if (!mounted) return;
      if (!writeOk) {
        setState(() {
          _uploading = false;
          _status =
              'WRITE permission denied. Grant in Health Connect and retry.';
        });
        return;
      }

      // ---- Workouts ----
      final workouts =
          (payload['workouts'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      int workoutsOk = 0;
      for (var i = 0; i < workouts.length; i++) {
        final w = workouts[i];
        setState(
          () => _status = 'Importing workout ${i + 1}/${workouts.length}...',
        );
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
        final samples =
            (payload[entry.key] as List?)?.cast<Map<String, dynamic>>() ?? [];
        numericTotal += samples.length;
        for (var i = 0; i < samples.length; i++) {
          if (i % 200 == 0) {
            if (!mounted) return;
            setState(
              () => _status =
                  'Importing ${entry.key} ${i + 1}/${samples.length}...',
            );
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
        final samples =
            (payload[entry.key] as List?)?.cast<Map<String, dynamic>>() ?? [];
        intervalTotal += samples.length;
        for (var i = 0; i < samples.length; i++) {
          if (i % 100 == 0) {
            if (!mounted) return;
            setState(
              () => _status =
                  'Importing ${entry.key} ${i + 1}/${samples.length}...',
            );
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
        _status =
            'Import complete:\n'
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
        permissions: _writeTypes.map((_) => HealthDataAccess.WRITE).toList(),
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

  // Max time span per Health Connect query. The plugin serializes each read's
  // ENTIRE result into one method-channel envelope on the Java heap; a full
  // 30-day window of heart-rate data (165k+ samples) OOM-crashed the app even
  // with largeHeap, so long windows are read in slices this wide and stitched
  // together on the Dart side.
  static const Duration _readChunk = Duration(days: 3);

  Future<List<HealthDataPoint>> _safeRead(
    HealthDataType t,
    DateTime start,
    DateTime end,
  ) async {
    final out = <HealthDataPoint>[];
    // Records overlapping a slice boundary are returned by both slices —
    // dedup by uuid so callers see each record once.
    final seen = <String>{};
    var cursor = start;
    while (cursor.isBefore(end)) {
      var sliceEnd = cursor.add(_readChunk);
      if (sliceEnd.isAfter(end)) sliceEnd = end;
      try {
        final slice = await _health.getHealthDataFromTypes(
          types: [t],
          startTime: cursor,
          endTime: sliceEnd,
        );
        for (final p in slice) {
          if (seen.add(p.uuid)) out.add(p);
        }
      } catch (e, st) {
        // Don't crash the caller — expected for unpermissioned types — but
        // log so it's still visible in the dev console.
        debugPrint('[_safeRead] ${t.name} $cursor..$sliceEnd failed: $e\n$st');
      }
      cursor = sliceEnd;
    }
    return out;
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
  Future<({Map<String, dynamic> payload, int totalSamples})> _buildSyncPayload(
    DateTime windowStart,
    DateTime now, {
    String labelSuffix = '',
  }) async {
    // Workouts use the package's special WORKOUT path (it aggregates
    // distance/calories/steps from related records). Separate read.
    final workouts = await _safeRead(HealthDataType.WORKOUT, windowStart, now);

    final workoutPayloads = workouts.map((w) {
      final wv = w.value is WorkoutHealthValue
          ? w.value as WorkoutHealthValue
          : null;
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
      payload[e.key] = samples.map(_numericSample).toList();
      totalSamples += samples.length;
    }
    for (final e in _intervalStreams.entries) {
      if (mounted) setState(() => _status = 'Reading ${e.key}$labelSuffix...');
      final samples = await _safeRead(e.value, windowStart, now);
      payload[e.key] = samples.map(_intervalSample).toList();
      totalSamples += samples.length;
    }

    return (payload: payload, totalSamples: totalSamples);
  }

  // [backfill] (debug): ignore the server watermark and upload the full
  // _historyWindow. Safe to repeat — the server's composite-key upsert
  // dedups everything; the payload carries "backfill": true so the server
  // can tell this overlap is deliberate.
  Future<void> _syncHealthData({bool backfill = false}) async {
    setState(() {
      _uploading = true;
      _status = 'Reading data from Health Connect...';
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      final now = DateTime.now();
      final DateTime windowStart;
      final String windowLabel;
      if (backfill) {
        windowStart = now.subtract(_historyWindow);
        windowLabel = 'backfill (${_historyWindow.inDays} days)';
      } else {
        setState(() => _status = 'Checking what the server already has...');
        final serverWatermark = await _fetchServerWatermark();
        if (!mounted) return;
        setState(() => _status = 'Reading data from Health Connect...');
        windowStart = serverWatermark != null
            ? serverWatermark.subtract(_watermarkOverlap)
            : now.subtract(_firstSyncWindow);
        final windowDays = now.difference(windowStart).inMinutes / (60 * 24);
        windowLabel = serverWatermark != null
            ? 'since last sync (${windowDays.toStringAsFixed(1)} days)'
            : 'full ${_firstSyncWindow.inHours}-hour window (first sync)';
      }

      final built = await _buildSyncPayload(windowStart, now);
      if (!mounted) return;
      final payload = built.payload;
      if (backfill) payload['backfill'] = true;
      final totalSamples = built.totalSamples;
      final workoutCount = (payload['workouts'] as List).length;

      final bodyBytes = utf8.encode(jsonEncode(payload));
      final sizeMB = (bodyBytes.length / 1024 / 1024).toStringAsFixed(2);
      setState(
        () => _status =
            'Uploading $workoutCount workouts + $totalSamples samples ($sizeMB MB)...',
      );

      final response = await http
          .post(
            Uri.parse('$_serverBase/workouts'),
            headers: {'Content-Type': 'application/json', ..._auth.authHeaders},
            body: bodyBytes,
          )
          .timeout(const Duration(seconds: 120));
      if (!mounted) return;

      final ok = response.statusCode >= 200 && response.statusCode < 300;
      // No watermark to persist — the server derives it from the data it
      // just ingested, and the next sync asks for it again.

      // 401 → token rejected. Drop it so the next sync attempt forces
      // sign-in, and show the auth card again instead of a noisy error.
      if (response.statusCode == 401) {
        await _auth.invalidate();
        if (!mounted) return;
        setState(() {
          _uploading = false;
          _status = 'Sign-in expired. Please sign in again, then re-tap Sync.';
        });
        return;
      }

      // Also upload any GPS routes other apps attached to their workouts in
      // Health Connect (Fitbit / Pixel Watch runs). Independent of the health
      // upload above — see SERVER_SCHEMA.md "Route tracks".
      setState(() => _status = 'Uploading Health Connect routes...');
      final hcRoutes = await _uploadHealthConnectRoutes(
        prefs,
        windowStart,
        now,
      );
      if (!mounted) return;
      if (hcRoutes.unauthorized) {
        await _auth.invalidate();
        if (!mounted) return;
        setState(() {
          _uploading = false;
          _status = 'Sign-in expired. Please sign in again, then re-tap Sync.';
        });
        return;
      }

      final routeMsg = (hcRoutes.uploaded == 0 && hcRoutes.failed == 0)
          ? ' No new routes.'
          : ' Routes: ${hcRoutes.uploaded} uploaded'
                '${hcRoutes.failed > 0 ? ", ${hcRoutes.failed} failed" : ""}.';
      final consentMsg = hcRoutes.pendingConsent > 0
          ? '\n${hcRoutes.pendingConsent} Health Connect route(s) unreadable — '
                'grant "Exercise routes → Always allow" in Health Connect → '
                'App permissions → XC Training Data, then Sync again.'
          : '';
      setState(() {
        _uploading = false;
        if (ok) {
          _status =
              'Synced $sizeMB MB ($windowLabel): $workoutCount workouts, $totalSamples samples. Server: ${response.statusCode}.$routeMsg$consentMsg';
        } else {
          _status =
              'Health upload failed: ${response.statusCode}.$routeMsg$consentMsg\n${response.body}';
        }
      });
      _refreshPendingData(); // recompute the home page's upload status
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _status = 'Sync error: $e';
      });
      _refreshPendingData();
    }
  }

  // Uploads GPS routes that OTHER apps (Fitbit, Pixel Watch, ...) attached to
  // their Health Connect workouts, as route_track payloads to POST /routes.
  // Routes the user hasn't consented to yet read back with no locations
  // (ConsentRequired) — counted in pendingConsent so the status can tell the
  // user to grant "Exercise routes" in Health Connect's app permissions.
  Future<({int uploaded, int failed, int pendingConsent, bool unauthorized})>
  _uploadHealthConnectRoutes(
    SharedPreferences prefs,
    DateTime windowStart,
    DateTime now,
  ) async {
    final points = await _safeRead(
      HealthDataType.WORKOUT_ROUTE,
      windowStart,
      now,
    );
    final done = (prefs.getStringList(_uploadedHcRoutesPrefsKey) ?? []).toSet();
    var uploaded = 0;
    var failed = 0;
    var pendingConsent = 0;
    for (final r in points) {
      final v = r.value;
      if (v is! WorkoutRouteHealthValue) continue;
      // The workout uuid is the stable identity of the route (and what the
      // server can join against the workouts table); fall back to the record
      // uuid if the package didn't surface it.
      final id = v.workoutUuid ?? r.uuid;
      if (done.contains(id)) continue;
      if (v.locations.isEmpty) {
        pendingConsent++;
        continue;
      }
      final locs = v.locations;
      var dist = 0.0;
      for (var i = 1; i < locs.length; i++) {
        dist += Geolocator.distanceBetween(
          locs[i - 1].latitude,
          locs[i - 1].longitude,
          locs[i].latitude,
          locs[i].longitude,
        );
      }
      final payload = {
        'type': 'route_track',
        'client_route_id': id,
        'source': 'health_connect',
        'source_workout_uuid': v.workoutUuid,
        'recorded_at': now.toUtc().toIso8601String(),
        'start_time': r.dateFrom.toUtc().toIso8601String(),
        'end_time': r.dateTo.toUtc().toIso8601String(),
        'duration_seconds': r.dateTo.difference(r.dateFrom).inSeconds,
        'distance_meters': dist,
        'point_count': locs.length,
        'points': [
          for (final p in locs)
            {
              'lat': p.latitude,
              'lng': p.longitude,
              'time': p.timestamp.toUtc().toIso8601String(),
              'accuracy_m': p.horizontalAccuracy,
              'altitude_m': p.altitude,
              'speed_mps': p.speed, // null on Android — HC routes omit speed
            },
        ],
      };
      try {
        final resp = await http
            .post(
              Uri.parse('$_serverBase/routes'),
              headers: {
                'Content-Type': 'application/json',
                ..._auth.authHeaders,
              },
              body: jsonEncode(payload),
            )
            .timeout(const Duration(seconds: 60));
        if (resp.statusCode == 401) {
          await prefs.setStringList(_uploadedHcRoutesPrefsKey, done.toList());
          return (
            uploaded: uploaded,
            failed: failed,
            pendingConsent: pendingConsent,
            unauthorized: true,
          );
        }
        if (resp.statusCode >= 200 && resp.statusCode < 300) {
          done.add(id);
          uploaded++;
        } else {
          debugPrint(
            '[hc-routes] $id rejected: ${resp.statusCode} ${resp.body}',
          );
          failed++;
        }
      } catch (e) {
        debugPrint('[hc-routes] upload of $id failed: $e');
        failed++; // network/timeout — retried next sync
      }
    }
    await prefs.setStringList(_uploadedHcRoutesPrefsKey, done.toList());
    return (
      uploaded: uploaded,
      failed: failed,
      pendingConsent: pendingConsent,
      unauthorized: false,
    );
  }

  // Marks the route-access onboarding step complete (granted or skipped).
  Future<void> _markRouteAccessDone() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_routeAccessDonePrefsKey, true);
    if (!mounted) return;
    setState(() => _routeAccessDone = true);
  }

  // Obtains Health Connect route access via the native dialogs (used by
  // onboarding and the debug page). Tries the blanket "Exercise routes"
  // permission first (Android 15+); if that's unavailable or denied, falls
  // back to the per-route consent dialog for the first consent-blocked route
  // (its "Allow all" option covers future runs).
  Future<void> _grantRouteAccess() async {
    // iOS has no separate route consent — HealthKit's standard permission
    // covers workout routes, and the route_access channel is Android-only.
    if (Platform.isIOS) {
      setState(() => _status = 'Route access is granted via Health on iOS.');
      await _markRouteAccessDone();
      return;
    }
    setState(() => _status = 'Requesting Health Connect route access...');
    try {
      final blanket = await _routeAccess.invokeMethod<bool>(
        'requestRoutesPermission',
      );
      if (!mounted) return;
      if (blanket == true) {
        setState(() => _status = 'Exercise-routes permission granted.');
        await _markRouteAccessDone();
        return;
      }
      // Fall back to per-route consent for the first blocked route.
      final now = DateTime.now();
      final points = await _safeRead(
        HealthDataType.WORKOUT_ROUTE,
        now.subtract(const Duration(days: 30)),
        now,
      );
      if (!mounted) return;
      String? uuid;
      for (final p in points) {
        final v = p.value;
        if (v is WorkoutRouteHealthValue && v.locations.isEmpty) {
          uuid = v.workoutUuid ?? p.uuid;
          break;
        }
      }
      if (uuid == null) {
        // Nothing blocked on consent — nothing to grant right now.
        setState(
          () =>
              _status = 'No consent-blocked routes found in the last 30 days.',
        );
        await _markRouteAccessDone();
        return;
      }
      final ok = await _routeAccess.invokeMethod<bool>('requestRouteConsent', {
        'sessionUuid': uuid,
      });
      if (!mounted) return;
      setState(
        () => _status = ok == true
            ? 'Route consent granted — pick "Allow all" next time to cover '
                  'future runs automatically.'
            : 'Route consent denied.',
      );
      if (ok == true) await _markRouteAccessDone();
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Route access request failed: $e');
    }
  }

  // Debug: full start-over. Asks the server to delete EVERYTHING this athlete
  // has uploaded (DELETE /me/data — see SERVER_SCHEMA.md "Data reset"), then
  // clears the local route-upload dedup list so the next Sync re-uploads the
  // full first-sync window and every route from scratch. (The sync watermark
  // lives on the server and resets with the data.) Local state is only
  // cleared after the server wipe succeeds, so a failed wipe can be retried.
  Future<void> _resetSyncWatermark() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Wipe server data?'),
        content: Text(
          'This deletes ALL data uploaded for your account on the server '
          'and resets local sync state. The next Sync re-uploads the full '
          '${_firstSyncWindow.inHours}-hour window and all saved routes.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            child: const Text('Delete & Reset'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _uploading = true;
      _status = 'Deleting server data...';
    });
    try {
      final resp = await http
          .delete(Uri.parse('$_serverBase/me/data'), headers: _auth.authHeaders)
          .timeout(const Duration(seconds: 60));
      if (!mounted) return;
      if (resp.statusCode == 401) {
        await _auth.invalidate();
        if (!mounted) return;
        setState(() {
          _uploading = false;
          _status = 'Sign-in expired. Please sign in again, then retry.';
        });
        return;
      }
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        final body = resp.body.length > 300
            ? '${resp.body.substring(0, 300)}…'
            : resp.body;
        setState(() {
          _uploading = false;
          _status =
              'Server delete failed: ${resp.statusCode}. '
              'Local sync state left untouched.\n$body';
        });
        return;
      }
      // The sync watermark lives on the server and was just deleted with the
      // data; only the local route-dedup list needs clearing.
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_uploadedHcRoutesPrefsKey);
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _status =
            'Server data deleted: ${resp.body}\nLocal sync state '
            'cleared — next Sync re-uploads the full '
            '${_firstSyncWindow.inHours}-hour window + all routes.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _status = 'Server delete failed: $e\nLocal sync state left untouched.';
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
        });
        return;
      }

      data.sort((a, b) => b.dateFrom.compareTo(a.dateFrom));
      final latest = data.first;
      final v = latest.value;
      final bpm = v is NumericHealthValue ? v.numericValue : v;

      setState(() {
        _status =
            'Latest heart rate: $bpm BPM at '
            '${latest.dateFrom.toLocal().toString().substring(0, 19)} '
            '(${data.length} readings in last 24h).';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = 'Error reading heart rate: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Loading persisted session → blank spinner (avoids a sign-in flash).
    if (_authLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    // Signed out → welcome screen: logo, message, sign-in. Nothing else.
    if (!_auth.isSignedIn) return _buildWelcome(theme);

    // Signed in but not set up → guided onboarding (permissions, route
    // access, automatic-upload choice).
    if (!_onboarded) return _buildOnboarding(theme);

    // The team doesn't record runs in-app, so release builds are Home + Runs
    // (workouts other apps wrote to Health Connect). Record and Debug tabs
    // exist only in debug builds, for development/testing.
    if (!kDebugMode) {
      final index = _pageIndex.clamp(0, 1);
      return Scaffold(
        appBar: AppBar(
          title: Text(index == 1 ? 'My Runs' : 'Chadwick XC Training'),
          centerTitle: true,
        ),
        body: index == 1 ? _buildHcRunsPage(theme) : _buildHomePage(theme),
        bottomNavigationBar: NavigationBar(
          selectedIndex: index,
          onDestinationSelected: (i) {
            setState(() {
              _pageIndex = i;
              if (i == 1) _hcRunsFuture = _loadHcRuns(); // refresh on open
            });
          },
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home),
              label: 'Home',
            ),
            NavigationDestination(
              icon: Icon(Icons.directions_run_outlined),
              selectedIcon: Icon(Icons.directions_run),
              label: 'Runs',
            ),
          ],
        ),
      );
    }

    // Debug builds: Home + Runs + Debug tools.
    final titles = <String>['Chadwick XC Training', 'My Runs', 'Debug Tools'];
    final index = _pageIndex.clamp(0, titles.length - 1);

    // Build only the active page — building all of them every frame would
    // re-run the Runs loaders on every setState.
    final Widget body;
    switch (index) {
      case 0:
        body = _buildHomePage(theme);
        break;
      case 1:
        body = _buildHcRunsPage(theme);
        break;
      default:
        body = _buildDebugPage(theme);
    }

    return Scaffold(
      appBar: AppBar(title: Text(titles[index]), centerTitle: true),
      body: body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (i) {
          setState(() {
            _pageIndex = i;
            if (i == 1) _hcRunsFuture = _loadHcRuns(); // refresh on open
          });
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.directions_run_outlined),
            selectedIcon: Icon(Icons.directions_run),
            label: 'Runs',
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

  // Signed-out landing: team logo, welcome message, and sign-in — no other
  // buttons, no bottom nav.
  Widget _buildWelcome(ThemeData theme) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(32),
                  child: Image.asset(
                    'assets/icon/app_icon.jpg',
                    width: 160,
                    height: 160,
                  ),
                ),
                const SizedBox(height: 32),
                Text(
                  'Chadwick XC Training',
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(
                  'Welcome! Sign in to share your training data with the team.',
                  style: theme.textTheme.bodyLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 40),
                FilledButton.icon(
                  onPressed: _auth.isGoogleConfigured
                      ? _signInWithGoogle
                      : null,
                  icon: const Icon(Icons.login),
                  label: Text(
                    _auth.isGoogleConfigured
                        ? 'Sign in with Google'
                        : 'Google Sign-In not configured',
                  ),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                  ),
                ),
                if (kDebugMode) ...[
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: _signInWithDevEmail,
                    child: const Text('Dev sign-in (debug builds only)'),
                  ),
                ],
                if (_signInError != null) ...[
                  const SizedBox(height: 24),
                  Text(
                    _signInError!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Post-sign-in setup: health permissions → route access → automatic-upload
  // choice. One step is active at a time; completed steps get a check.
  Widget _buildOnboarding(ThemeData theme) {
    final autoDone = _autoSyncEnabled != null;

    Widget step(int n, String title, bool done, bool active) {
      return ListTile(
        leading: done
            ? Icon(Icons.check_circle, color: theme.colorScheme.primary)
            : CircleAvatar(
                radius: 14,
                backgroundColor: active
                    ? theme.colorScheme.primary
                    : theme.colorScheme.surfaceContainerHighest,
                foregroundColor: active
                    ? theme.colorScheme.onPrimary
                    : theme.colorScheme.onSurfaceVariant,
                child: Text('$n'),
              ),
        title: Text(
          title,
          style: active ? const TextStyle(fontWeight: FontWeight.w600) : null,
        ),
      );
    }

    final healthActive = !_permissionsGranted;
    final routeActive = _permissionsGranted && !_routeAccessDone;
    final autoActive = _permissionsGranted && _routeAccessDone && !autoDone;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Chadwick XC Training'),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              "Let's get you set up",
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              Platform.isIOS
                  ? 'Two quick steps so your training data reaches the team.'
                  : 'Three quick steps so your training data reaches the team.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            Card(
              child: Column(
                children: [
                  step(
                    1,
                    'Allow health data access',
                    _permissionsGranted,
                    healthActive,
                  ),
                  // Health Connect needs a separate route-consent step;
                  // HealthKit covers routes with the standard permission, so
                  // this step doesn't exist on iOS.
                  if (!Platform.isIOS)
                    step(
                      2,
                      'Allow workout route access',
                      _routeAccessDone,
                      routeActive,
                    ),
                  step(
                    Platform.isIOS ? 2 : 3,
                    'Choose automatic upload',
                    autoDone,
                    autoActive,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            if (healthActive)
              FilledButton.icon(
                onPressed: _requestPermissions,
                icon: const Icon(Icons.favorite),
                label: const Text('Allow health data access'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                ),
              )
            else if (routeActive) ...[
              FilledButton.icon(
                onPressed: _grantRouteAccess,
                icon: const Icon(Icons.route),
                label: const Text('Allow workout route access'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _markRouteAccessDone,
                child: const Text('Skip for now'),
              ),
            ] else if (autoActive) ...[
              Text(
                'Upload your workouts automatically whenever you open the app?',
                style: theme.textTheme.bodyLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => _setAutoSync(true),
                icon: const Icon(Icons.cloud_upload),
                label: const Text('Yes, upload automatically'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () => _setAutoSync(false),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                ),
                child: const Text("No, I'll sync manually"),
              ),
            ],
            const SizedBox(height: 24),
            Text(
              _status,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
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

  // Loads workouts other apps wrote to Health Connect (last 30 days) and
  // groups time-overlapping ones into logical runs — see _HcRun.
  Future<List<_HcRun>> _loadHcRuns() async {
    final now = DateTime.now();
    final workouts = await _safeRead(
      HealthDataType.WORKOUT,
      now.subtract(_historyWindow),
      now,
    );
    workouts.sort((a, b) => a.dateFrom.compareTo(b.dateFrom));
    final runs = <_HcRun>[];
    for (final w in workouts) {
      if (runs.isNotEmpty && runs.last.overlaps(w)) {
        runs.last.add(w);
      } else {
        runs.add(_HcRun(w));
      }
    }
    return runs.reversed.toList(); // newest first
  }

  // 'com.fitbit.FitbitMobile' -> 'Fitbit', 'com.strava' -> 'Strava', etc.
  String _prettySource(String source) {
    const known = {
      'com.strava': 'Strava',
      'com.fitbit.FitbitMobile': 'Fitbit',
      'com.google.android.apps.fitness': 'Google Fit',
      'com.google.android.apps.healthdata': 'Health Connect',
    };
    final k = known[source];
    if (k != null) return k;
    final seg = source.split('.').last;
    return seg.isEmpty ? source : seg[0].toUpperCase() + seg.substring(1);
  }

  // 'TRAIL_RUNNING' -> 'Trail running'.
  String _prettyActivity(String name) {
    final lower = name.replaceAll('_', ' ').toLowerCase();
    return lower[0].toUpperCase() + lower.substring(1);
  }

  IconData _activityIcon(String name) {
    if (name.contains('RUN')) return Icons.directions_run;
    if (name.contains('WALK') || name.contains('HIK')) {
      return Icons.directions_walk;
    }
    if (name.contains('BIK') || name.contains('CYCL')) {
      return Icons.pedal_bike;
    }
    if (name.contains('SWIM')) return Icons.pool;
    return Icons.fitness_center;
  }

  // Runs tab: workouts recorded by other apps (Fitbit, Strava, ...), grouped
  // per physical run. Tapping shows the GPS route when one is available.
  Widget _buildHcRunsPage(ThemeData theme) {
    return FutureBuilder<List<_HcRun>>(
      future: _hcRunsFuture ??= _loadHcRuns(),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final runs = snap.data ?? [];
        if (runs.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Text(
                'No workouts found in the last 30 days.\n'
                'Runs recorded by Fitbit, Strava, and other apps connected '
                'to Health Connect show up here.',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        return ListView.separated(
          itemCount: runs.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final r = runs[i];
            final dist = r.distanceMeters;
            final parts = <String>[
              if (dist != null) '${(dist / 1000).toStringAsFixed(2)} km',
              _fmtDuration(r.duration),
              r.sources.map(_prettySource).join(' + '),
            ];
            return ListTile(
              leading: Icon(_activityIcon(r.activityType)),
              title: Text(
                '${_prettyActivity(r.activityType)} · '
                '${_fmtRunDate(r.start.toUtc())}',
              ),
              subtitle: Text(parts.join(' · ')),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _openHcRun(r),
            );
          },
        );
      },
    );
  }

  // Fetches the GPS route for a grouped run: the route record whose workout
  // uuid belongs to the group (any overlapping route as fallback).
  Future<({List<LatLng>? points, bool consentBlocked})> _routeForRun(
    _HcRun run,
  ) async {
    final records = await _safeRead(
      HealthDataType.WORKOUT_ROUTE,
      run.start.subtract(const Duration(minutes: 5)),
      run.end.add(const Duration(minutes: 5)),
    );
    var consentBlocked = false;
    for (final p in records) {
      final v = p.value;
      if (v is! WorkoutRouteHealthValue) continue;
      final matches =
          v.workoutUuid == null ||
          run.uuids.contains(v.workoutUuid) ||
          run.uuids.contains(p.uuid);
      if (!matches) continue;
      if (v.locations.isNotEmpty) {
        return (
          points: [
            for (final l in v.locations) LatLng(l.latitude, l.longitude),
          ],
          consentBlocked: false,
        );
      }
      consentBlocked = true; // route exists but HC withheld the points
    }
    return (points: null, consentBlocked: consentBlocked);
  }

  Future<void> _openHcRun(_HcRun run) async {
    final route = await _routeForRun(run);

    // Average / max heart rate over the run window, if any HR was recorded.
    int? avgHr, maxHr;
    try {
      final hr = await _safeRead(HealthDataType.HEART_RATE, run.start, run.end);
      final bpms = <double>[
        for (final p in hr)
          if (p.value is NumericHealthValue)
            (p.value as NumericHealthValue).numericValue.toDouble(),
      ];
      if (bpms.isNotEmpty) {
        avgHr = (bpms.reduce((a, b) => a + b) / bpms.length).round();
        maxHr = bpms.reduce((a, b) => a > b ? a : b).round();
      }
    } catch (e) {
      debugPrint('HR read for run failed: $e');
    }
    if (!mounted) return;

    final km = run.distanceMeters != null ? run.distanceMeters! / 1000 : null;
    final energy = run.energyKcal;
    final steps = run.steps;
    final stats = <_RunStat>[
      if (km != null)
        _RunStat(Icons.straighten, 'Distance', '${km.toStringAsFixed(2)} km'),
      _RunStat(Icons.timer_outlined, 'Duration', _fmtDuration(run.duration)),
      if (km != null && km > 0)
        _RunStat(Icons.speed, 'Pace', _fmtPace(run.duration, km)),
      if (energy != null)
        _RunStat(
          Icons.local_fire_department,
          'Energy',
          '${energy.round()} kcal',
        ),
      if (steps != null) _RunStat(Icons.directions_walk, 'Steps', '$steps'),
      if (avgHr != null) _RunStat(Icons.favorite, 'Avg HR', '$avgHr bpm'),
      if (maxHr != null)
        _RunStat(Icons.favorite_border, 'Max HR', '$maxHr bpm'),
    ];

    final pts = route.points;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _HcRunDetailPage(
          title:
              '${_prettyActivity(run.activityType)} · ${_fmtRunDate(run.start.toUtc())}',
          subtitle: run.sources.map(_prettySource).join(' + '),
          stats: stats,
          points: (pts != null && pts.length >= 2) ? pts : null,
          consentBlocked: route.consentBlocked,
        ),
      ),
    );
  }

  // Pace as m:ss per km.
  String _fmtPace(Duration d, double km) {
    final secPerKm = (d.inSeconds / km).round();
    final m = secPerKm ~/ 60;
    final s = secPerKm % 60;
    return '$m:${s.toString().padLeft(2, '0')} /km';
  }

  String _fmtRunDate(DateTime utc) {
    final d = utc.toLocal();
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final ampm = d.hour < 12 ? 'AM' : 'PM';
    final min = d.minute.toString().padLeft(2, '0');
    return '${months[d.month - 1]} ${d.day}, ${d.year}  $h:$min $ampm';
  }

  // Signed-in home: upload status front and center. The Sync button appears
  // only when there is data the server doesn't have yet.
  Widget _buildHomePage(ThemeData theme) {
    final pending = _pendingSamples;
    final behind = pending != null && pending != 0;

    final String statusLine;
    final IconData statusIcon;
    if (_uploading) {
      statusIcon = Icons.cloud_upload;
      statusLine = _status; // live progress from the sync
    } else if (pending == null) {
      statusIcon = Icons.cloud_queue;
      statusLine = 'Checking for new data…';
    } else if (pending == -2) {
      statusIcon = Icons.cloud_off;
      statusLine = 'Could not reach the server — tap Sync to retry.';
    } else if (pending == -1) {
      statusIcon = Icons.cloud_off;
      statusLine =
          'Nothing uploaded yet — tap Sync to upload your last '
          '${_firstSyncWindow.inHours} hours.';
    } else if (pending == 0) {
      statusIcon = Icons.cloud_done;
      statusLine = 'All data uploaded.';
    } else {
      statusIcon = Icons.cloud_upload;
      statusLine = '$pending new samples since your last sync.';
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildAuthCard(theme),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (_uploading || pending == null)
                        const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else
                        Icon(statusIcon, color: theme.colorScheme.primary),
                      const SizedBox(width: 12),
                      Text(
                        'Upload status',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(statusLine),
                  if (!_uploading && _lastSyncAt != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Last synced: ${_fmtRunDate(_lastSyncAt!.toUtc())}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (!_uploading && behind)
            FilledButton.icon(
              onPressed: _syncHealthData,
              icon: const Icon(Icons.cloud_upload),
              label: const Text('Sync to Server'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
            ),
          const SizedBox(height: 16),
          Card(
            child: SwitchListTile(
              title: const Text('Upload automatically'),
              subtitle: const Text('Sync whenever the app opens'),
              value: _autoSyncEnabled ?? false,
              onChanged: _uploading ? null : (v) => _setAutoSync(v),
            ),
          ),
          if (!_uploading) ...[
            const SizedBox(height: 16),
            Text(
              _status,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
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
      IconData icon,
      String label,
      VoidCallback onPressed,
    ) {
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
          // Independent of health permissions — wipes server data + sync state.
          debugButton(
            Icons.restart_alt,
            'Reset (wipe server + start over)',
            _resetSyncWatermark,
          ),
          const SizedBox(height: 8),
          if (_permissionsGranted) ...[
            debugButton(
              Icons.history,
              'Upload Past ${_historyWindow.inDays} Days (backfill)',
              () {
                if (!_uploading) _syncHealthData(backfill: true);
              },
            ),
            const SizedBox(height: 8),
            debugButton(Icons.favorite, 'Read Heart Rate', _readHeartRate),
            const SizedBox(height: 8),
            debugButton(
              Icons.search,
              'Discover Workout Data',
              _discoverWorkoutData,
            ),
            const SizedBox(height: 8),
            debugButton(
              Icons.travel_explore,
              'Scan All Data (30d)',
              _discoverAllData,
            ),
            const SizedBox(height: 8),
            debugButton(Icons.file_download, 'Export to File', _exportToFile),
            const SizedBox(height: 8),
            debugButton(
              Icons.edit,
              'Request WRITE Permissions',
              _requestWritePermissions,
            ),
            const SizedBox(height: 8),
            debugButton(Icons.file_upload, 'Import from File', _importFromFile),
          ],
        ],
      ),
    );
  }
}
