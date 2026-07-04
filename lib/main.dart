import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui; // Path is qualified to avoid latlong2's Path class

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

// shared_preferences key — stores the ISO-8601 UTC timestamp of the most
// recent successful sync. Next sync uses this as window_start. Falls back to
// 30 days ago when absent (first run or after a reinstall).
const String _lastSyncPrefsKey = 'last_sync_at';
const Duration _firstSyncWindow = Duration(days: 30);

// shared_preferences key — filenames of route tracks already uploaded to the
// server, so Sync only sends new ones. (Server dedup is idempotent anyway; this
// just avoids re-POSTing every track on every sync.)
const String _uploadedRoutesPrefsKey = 'uploaded_route_files';

// shared_preferences key — Health Connect route ids (workout uuid) already
// uploaded to the server, so Sync only sends new ones.
const String _uploadedHcRoutesPrefsKey = 'uploaded_hc_routes';

// Re-query an overlap behind the watermark on every incremental sync, to catch
// late-arriving Health Connect samples. The watermark is a single global max
// across all streams, so live HR pins it near "now"; but Fitbit derives resting
// HR, HRV, and sleep from overnight data and delivers them hours late, with a
// dateTo well behind that global max. A 1h overlap missed them — use 24h so a
// late-delivered sample still falls inside the next sync's window. The server's
// UUID upsert dedup makes the wider re-query harmless.
const Duration _watermarkOverlap = Duration(hours: 24);

// Zoom the Record map opens at, and snaps back to when the recenter button is
// tapped. 18 is a tight, street-level view.
const double _recordMapZoom = 18;

// Moving-average window for smoothing the *displayed* GPS path — tames the
// zigzag from slow walking / GPS jitter. Raw points are kept intact for upload;
// only the drawn polyline is smoothed. Higher = smoother but rounds corners
// more; set to 1 to disable.
const int _pathSmoothingWindow = 7;

// Recording-quality gates. Drop fixes worse than _gpsAccuracyThresholdM meters
// (a poor fix scatters the path and inflates distance), and reject any leg
// implying a speed above _gpsMaxSpeedMps — a GPS multipath spike, not real
// movement (~12 m/s is faster than a world-class sprint, so legit running is
// never dropped). These guard the recorded distance metric only.
const double _gpsAccuracyThresholdM = 25;
const double _gpsMaxSpeedMps = 12;

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

// Summary of a saved run, parsed from a track JSON file for the Runs list.
class _RunSummary {
  final File file;
  final DateTime start;
  final double km;
  final Duration duration;
  final int pointCount;

  _RunSummary({
    required this.file,
    required this.start,
    required this.km,
    required this.duration,
    required this.pointCount,
  });
}

// Read-only map view of one saved run: its path, with start/end markers,
// framed to fit the whole route.
class _RunMapPage extends StatelessWidget {
  final String title;
  final String subtitle;
  final List<LatLng> points;

  const _RunMapPage({
    required this.title,
    required this.subtitle,
    required this.points,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
      body: points.isEmpty
          ? const Center(child: Text('No points in this run.'))
          : FlutterMap(
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
                  urlTemplate:
                      'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
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
            ),
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

// A compass needle (red = north, grey = south) that counter-rotates with the
// map so it keeps pointing at true north — like Google Maps' compass button.
class _CompassNeedle extends StatelessWidget {
  final double bearingDeg;
  const _CompassNeedle({required this.bearingDeg});

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: -bearingDeg * math.pi / 180,
      child: CustomPaint(size: const Size(18, 18), painter: _NeedlePainter()),
    );
  }
}

class _NeedlePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final half = size.width * 0.28;
    final north = ui.Path()
      ..moveTo(cx, 0)
      ..lineTo(cx - half, cy)
      ..lineTo(cx + half, cy)
      ..close();
    final south = ui.Path()
      ..moveTo(cx, size.height)
      ..lineTo(cx - half, cy)
      ..lineTo(cx + half, cy)
      ..close();
    canvas.drawPath(north, Paint()..color = const Color(0xFFD32F2F)); // N: red
    canvas.drawPath(south, Paint()..color = const Color(0xFF9E9E9E)); // S: grey
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
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

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  // Native bridge for Health Connect's route-consent dialogs (MainActivity.kt).
  // The health plugin can't request route access — see _grantRouteAccess.
  static const MethodChannel _routeAccess =
      MethodChannel('xctraining/route_access');

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
  bool _startingRun = false; // re-entrancy guard for _startRecording
  final List<_TrackPoint> _track = [];
  double _distanceMeters = 0;
  DateTime? _recordStart;
  Duration _elapsed = Duration.zero;
  StreamSubscription<Position>? _posSub;
  Timer? _tick;

  // Map state for the Record page. _lastFix drives the "you are here" marker
  // and camera follow; updated by a live preview stream while on the tab (idle)
  // and by each recording fix.
  final MapController _mapController = MapController();
  LatLng? _lastFix;
  // Last idle-preview GPS error, shown in the Record map banner instead of an
  // indefinite "Locating you…" when no fix has arrived yet. Cleared on a fix.
  String? _gpsError;
  // Idle location preview stream (Record tab, not recording).
  StreamSubscription<Position>? _previewSub;
  // Tracked from the map's onPositionChanged so the recenter button can reflect
  // state: crosshair when off-center, compass (needle to north) when centered
  // but rotated.
  double _mapRotation = 0;
  bool _mapCentered = true;

  // Memoized smoothed polyline for the Record map, keyed on _track.length so a
  // per-second timer tick doesn't re-run the O(n·window) smoothing when the
  // track hasn't grown. Points are only ever appended, so length is a
  // sufficient invalidation key.
  List<LatLng> _smoothedTrack = const [];
  int _smoothedAtLength = -1;

  // Cached future for the Runs tab — refreshed when the tab is opened so a
  // just-saved run shows up, without re-reading the dir on every rebuild.
  Future<List<_RunSummary>>? _runsFuture;

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
    WidgetsBinding.instance.addObserver(this);
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
    WidgetsBinding.instance.removeObserver(this);
    _posSub?.cancel();
    _previewSub?.cancel();
    _tick?.cancel();
    _mapController.dispose();
    super.dispose();
  }

  // Stop the idle location preview when the app is backgrounded, and resume it
  // on return (only if we're on the Record tab and not recording). A recording
  // run is left alone — its foreground service is meant to keep GPS alive while
  // backgrounded.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_recording) return;
    if (state == AppLifecycleState.resumed) {
      if (_pageIndex == 1) _startLocationPreview();
    } else if (state == AppLifecycleState.paused) {
      _stopLocationPreview();
    }
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
    // Guard re-entrancy: _recording isn't set until after the permission await
    // below, so a fast double-tap (or a tap during the permission dialog) could
    // otherwise start a second stream + timer and orphan the first. _startingRun
    // is set synchronously, before the first await.
    if (_recording || _startingRun) return;
    _startingRun = true;
    try {
      if (!await _ensureLocationPermission()) return;
      if (!mounted) return;
      _stopLocationPreview(); // the recording stream takes over
      setState(() {
        _recording = true;
        _track.clear();
        _distanceMeters = 0;
        _elapsed = Duration.zero;
        _recordStart = DateTime.now();
        _status = 'Recording run — you can lock the screen; '
            'a notification keeps it tracking.';
      });

      // AndroidSettings (vs plain LocationSettings) lets geolocator promote its
      // location service to a foreground service via foregroundNotificationConfig,
      // which is what keeps GPS flowing with the screen off / app backgrounded.
      // iOS would need AppleSettings here when iOS support is added.
      final settings = AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5, // meters between fixes — filters GPS jitter at rest
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'XC Training — recording run',
          notificationText: 'Tracking your GPS route',
          notificationChannelName: 'Run recording',
          enableWakeLock: true, // keep the CPU awake for GPS while screen is off
          setOngoing: true, // can't be swiped away mid-run
        ),
      );
      _posSub = Geolocator.getPositionStream(locationSettings: settings).listen(
        (pos) {
          if (!mounted) return;
          final fix = LatLng(pos.latitude, pos.longitude);
          // Don't RECORD low-quality fixes — a poor-accuracy fix scatters the
          // path and its out-and-back leg inflates the distance — but do keep
          // the marker/camera live so the map doesn't freeze in weak GPS. (A
          // poor fix is roughly right, just imprecise; jump spikes below are
          // wrong positions, so those don't move the marker either.)
          if (pos.accuracy > _gpsAccuracyThresholdM) {
            setState(() => _lastFix = fix);
            _followCamera(fix);
            return;
          }
          double? leg;
          if (_track.isNotEmpty) {
            final last = _track.last;
            leg = Geolocator.distanceBetween(
                last.lat, last.lng, pos.latitude, pos.longitude);
            // Reject implausible jumps (GPS multipath spikes): a leg implying a
            // speed no runner can hit is a bad fix, not real distance.
            final dt =
                pos.timestamp.difference(last.time).inMilliseconds / 1000.0;
            if (dt > 0 && leg / dt > _gpsMaxSpeedMps) return;
          }
          setState(() {
            if (leg != null) _distanceMeters += leg;
            _track.add(_TrackPoint(
              lat: pos.latitude,
              lng: pos.longitude,
              time: pos.timestamp,
              accuracy: pos.accuracy,
              altitude: pos.altitude,
              speed: pos.speed,
            ));
            _lastFix = fix;
          });
          _followCamera(fix); // keep the map centered on the runner
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
    } finally {
      _startingRun = false;
    }
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
    if (_pageIndex == 1) _startLocationPreview(); // resume idle preview

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
        // The run is saved (from the points snapshot above) — clear the live
        // track so its polyline doesn't linger on the idle preview map. Keep
        // _lastFix so the "you are here" marker still tracks the user.
        _track.clear();
        _distanceMeters = 0;
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

  // Recenter the map on [target] at the current zoom. Guarded: MapController
  // .move throws if the map widget isn't mounted yet.
  void _followCamera(LatLng target) {
    try {
      _mapController.move(target, _mapController.camera.zoom);
    } catch (_) {
      // Map not ready — the next fix or the initial fit will catch up.
    }
  }

  // Recenter button: if the map has been panned away from the current
  // location, recenter on it; if it's already centered, reset the bearing to
  // north (handy after a two-finger rotate).
  void _recenterOrAlignNorth() {
    if (_lastFix == null) return;
    final cam = _mapController.camera;
    final offBy = Geolocator.distanceBetween(
      cam.center.latitude,
      cam.center.longitude,
      _lastFix!.latitude,
      _lastFix!.longitude,
    );
    if (offBy > 25) {
      _mapController.move(_lastFix!, _recordMapZoom); // recenter at default zoom
      setState(() => _mapCentered = true);
    } else {
      _mapController.rotate(0); // already centered → align north-up
      // Update state directly: a programmatic rotate doesn't reliably fire
      // onPositionChanged, so the needle would otherwise stay tilted.
      setState(() => _mapRotation = 0);
    }
  }

  // Live location preview while on the Record tab and NOT recording, so the
  // marker keeps tracking the user. Plain (non-foreground) stream: Android
  // pauses it when the app is backgrounded, and we stop it when leaving the tab
  // or when recording starts — so it isn't a battery sink.
  Future<void> _startLocationPreview() async {
    if (_recording || _previewSub != null) return;
    if (!await _ensureLocationPermission()) return;
    // State may have changed during the permission await.
    if (!mounted || _recording || _previewSub != null || _pageIndex != 1) {
      return;
    }
    _previewSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      ),
    ).listen(
      (pos) {
        if (!mounted) return;
        final fix = LatLng(pos.latitude, pos.longitude);
        setState(() {
          _lastFix = fix;
          _gpsError = null; // a fix arrived — clear any prior preview error
        });
        // Follow only if centered, so panning the idle map isn't yanked back.
        if (_mapCentered) _followCamera(fix);
      },
      // Don't swallow it: surface in the Record banner (and the dev console) so
      // a broken preview doesn't sit on "Locating you…" forever.
      onError: (e) {
        debugPrint('[preview] GPS error: $e');
        if (!mounted) return;
        setState(() => _gpsError = 'GPS unavailable: $e');
      },
    );
  }

  void _stopLocationPreview() {
    _previewSub?.cancel();
    _previewSub = null;
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
    } finally {
      controller.dispose();
    }
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
            if (!mounted) return;
            setState(() => _status =
                'Importing ${entry.key} ${i + 1}/${samples.length}...');
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
            if (!mounted) return;
            setState(() => _status =
                'Importing ${entry.key} ${i + 1}/${samples.length}...');
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

      // Also upload any recorded GPS route tracks (see SERVER_SCHEMA.md
      // "Route tracks"). Independent of the health upload above.
      setState(() => _status = 'Uploading recorded routes...');
      final routes = await _uploadRouteTracks(prefs);
      if (!mounted) return;
      if (routes.unauthorized) {
        await _auth.invalidate();
        if (!mounted) return;
        setState(() {
          _uploading = false;
          _status = 'Sign-in expired. Please sign in again, then re-tap Sync.';
        });
        return;
      }

      // ...and any GPS routes other apps attached to their workouts in
      // Health Connect (Fitbit / Pixel Watch runs).
      setState(() => _status = 'Uploading Health Connect routes...');
      final hcRoutes =
          await _uploadHealthConnectRoutes(prefs, windowStart, now);
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

      final routesUploaded = routes.uploaded + hcRoutes.uploaded;
      final routesFailed = routes.failed + hcRoutes.failed;
      final routeMsg = (routesUploaded == 0 && routesFailed == 0)
          ? ' No new routes.'
          : ' Routes: $routesUploaded uploaded'
              '${hcRoutes.uploaded > 0 ? " (${hcRoutes.uploaded} from Health Connect)" : ""}'
              '${routesFailed > 0 ? ", $routesFailed failed" : ""}.';
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
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _status = 'Sync error: $e';
      });
    }
  }

  // Uploads saved route tracks the client hasn't sent yet to POST /routes,
  // tracking which filenames are done in shared_preferences. Files stay on
  // device (so the Runs tab keeps them); failures are retried next sync.
  Future<({int uploaded, int failed, bool unauthorized})> _uploadRouteTracks(
      SharedPreferences prefs) async {
    final dir = await getApplicationDocumentsDirectory();
    final files = dir.listSync().whereType<File>().where((f) =>
        f.path.endsWith('.json') && f.path.contains('xc_route_'));
    final done = (prefs.getStringList(_uploadedRoutesPrefsKey) ?? []).toSet();
    var uploaded = 0;
    var failed = 0;
    for (final f in files) {
      final name = f.uri.pathSegments.last;
      if (done.contains(name)) continue; // already uploaded
      try {
        final body = await f.readAsString();
        final resp = await http
            .post(
              Uri.parse('$_serverBase/routes'),
              headers: {
                'Content-Type': 'application/json',
                ..._auth.authHeaders,
              },
              body: body,
            )
            .timeout(const Duration(seconds: 60));
        if (resp.statusCode == 401) {
          await prefs.setStringList(_uploadedRoutesPrefsKey, done.toList());
          return (uploaded: uploaded, failed: failed, unauthorized: true);
        }
        if (resp.statusCode >= 200 && resp.statusCode < 300) {
          done.add(name);
          uploaded++;
        } else {
          debugPrint('[routes] $name rejected: ${resp.statusCode} ${resp.body}');
          failed++;
        }
      } catch (e) {
        debugPrint('[routes] upload of $name failed: $e');
        failed++; // network/timeout — retried next sync
      }
    }
    await prefs.setStringList(_uploadedRoutesPrefsKey, done.toList());
    return (uploaded: uploaded, failed: failed, unauthorized: false);
  }

  // Uploads GPS routes that OTHER apps (Fitbit, Pixel Watch, ...) attached to
  // their Health Connect workouts, as route_track payloads to POST /routes.
  // Routes the user hasn't consented to yet read back with no locations
  // (ConsentRequired) — counted in pendingConsent so the status can tell the
  // user to grant "Exercise routes" in Health Connect's app permissions.
  Future<({int uploaded, int failed, int pendingConsent, bool unauthorized})>
      _uploadHealthConnectRoutes(
          SharedPreferences prefs, DateTime windowStart, DateTime now) async {
    final points =
        await _safeRead(HealthDataType.WORKOUT_ROUTE, windowStart, now);
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
            locs[i].longitude);
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
            }
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
              '[hc-routes] $id rejected: ${resp.statusCode} ${resp.body}');
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

  // Debug: obtain Health Connect route access via the native dialogs. Tries
  // the blanket "Exercise routes" permission first (Android 15+); if that's
  // unavailable or denied, falls back to the per-route consent dialog for the
  // first consent-blocked route (its "Allow all" option covers future runs).
  Future<void> _grantRouteAccess() async {
    setState(() => _status = 'Requesting Health Connect route access...');
    try {
      final blanket =
          await _routeAccess.invokeMethod<bool>('requestRoutesPermission');
      if (!mounted) return;
      if (blanket == true) {
        setState(() => _status =
            'Exercise-routes permission granted. Tap Sync to upload routes.');
        return;
      }
      // Fall back to per-route consent for the first blocked route.
      final now = DateTime.now();
      final points = await _safeRead(HealthDataType.WORKOUT_ROUTE,
          now.subtract(const Duration(days: 30)), now);
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
        setState(() => _status =
            'No consent-blocked routes found in the last 30 days.');
        return;
      }
      final ok = await _routeAccess
          .invokeMethod<bool>('requestRouteConsent', {'sessionUuid': uuid});
      if (!mounted) return;
      setState(() => _status = ok == true
          ? 'Route consent granted — pick "Allow all" next time to cover '
              'future runs automatically. Tap Sync to upload.'
          : 'Route consent denied.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Route access request failed: $e');
    }
  }

  // Debug: rewind the health sync watermark 24h AND clear the route-upload
  // tracking, so the next Sync re-uploads the last day of health data plus all
  // saved route tracks (server dedup makes both re-uploads idempotent).
  Future<void> _resetSyncWatermark() async {
    final prefs = await SharedPreferences.getInstance();
    final t = DateTime.now().subtract(const Duration(hours: 24));
    await prefs.setString(_lastSyncPrefsKey, t.toUtc().toIso8601String());
    await prefs.remove(_uploadedRoutesPrefsKey); // re-send saved routes too
    await prefs.remove(_uploadedHcRoutesPrefsKey); // and Health Connect routes
    if (!mounted) return;
    setState(() => _status =
        'Reset: health watermark −24h and route-upload tracking cleared. '
        'Next Sync re-uploads the last day + all saved routes.');
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

    // Tabs: Home, Record, Runs (always); Debug only in debug builds.
    final titles = <String>[
      'XC Training Data',
      'Record Run',
      'My Runs',
      if (kDebugMode) 'Debug Tools',
    ];
    final index = _pageIndex.clamp(0, titles.length - 1);

    // Build only the active page. Building all of them every frame would re-run
    // _buildRunsPage (which reads saved tracks from disk) on every setState —
    // e.g. once per second while recording.
    final Widget body;
    switch (index) {
      case 0:
        body = _buildHomePage(theme);
        break;
      case 1:
        body = _buildRecordPage(theme);
        break;
      case 2:
        body = _buildRunsPage(theme);
        break;
      default:
        body = _buildDebugPage(theme);
    }

    final destinations = <NavigationDestination>[
      const NavigationDestination(
        icon: Icon(Icons.home_outlined),
        selectedIcon: Icon(Icons.home),
        label: 'Home',
      ),
      const NavigationDestination(
        icon: Icon(Icons.fiber_manual_record_outlined),
        selectedIcon: Icon(Icons.fiber_manual_record),
        label: 'Record',
      ),
      const NavigationDestination(
        icon: Icon(Icons.route_outlined),
        selectedIcon: Icon(Icons.route),
        label: 'Runs',
      ),
      if (kDebugMode)
        const NavigationDestination(
          icon: Icon(Icons.bug_report_outlined),
          selectedIcon: Icon(Icons.bug_report),
          label: 'Debug',
        ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(titles[index]),
        centerTitle: true,
      ),
      body: body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (i) {
          setState(() {
            _pageIndex = i;
            if (i == 2) _runsFuture = _loadRuns(); // Runs tab — refresh list
          });
          // Run the idle location preview only while on the Record tab.
          if (i == 1) {
            _startLocationPreview();
          } else {
            _stopLocationPreview();
          }
        },
        destinations: destinations,
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

  // Full-screen Record page: live map with a follow marker, the growing path
  // polyline, live stats, and the Start/Stop control.
  // Smoothed polyline for the Record map, recomputed only when the track grows.
  List<LatLng> _recordPolyline() {
    if (_smoothedAtLength != _track.length) {
      _smoothedAtLength = _track.length;
      _smoothedTrack =
          smoothPath([for (final p in _track) LatLng(p.lat, p.lng)]);
    }
    return _smoothedTrack;
  }

  Widget _buildRecordPage(ThemeData theme) {
    final polyline = _recordPolyline();
    final km = (_distanceMeters / 1000).toStringAsFixed(2);
    // Show the compass whenever the map is centered on the user — the needle
    // points straight up/down when aligned to north, and rotates to true north
    // when the map is turned. The crosshair "recenter" icon shows only when the
    // map has been panned off the current location.
    final showCompass = _mapCentered;

    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: _lastFix ?? const LatLng(0, 0),
            initialZoom: _recordMapZoom,
            onPositionChanged: (camera, hasGesture) {
              final centered = _lastFix == null
                  ? true
                  : Geolocator.distanceBetween(
                        camera.center.latitude,
                        camera.center.longitude,
                        _lastFix!.latitude,
                        _lastFix!.longitude,
                      ) <=
                      25;
              if (camera.rotation != _mapRotation ||
                  centered != _mapCentered) {
                setState(() {
                  _mapRotation = camera.rotation;
                  _mapCentered = centered;
                });
              }
            },
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.github.briansp2020.xctraining',
            ),
            if (polyline.length >= 2)
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: polyline,
                    strokeWidth: 5,
                    color: theme.colorScheme.primary,
                  ),
                ],
              ),
            if (_lastFix != null)
              MarkerLayer(
                markers: [
                  Marker(
                    point: _lastFix!,
                    width: 22,
                    height: 22,
                    child: _locationDot(theme.colorScheme.primary),
                  ),
                ],
              ),
          ],
        ),
        if (_lastFix == null && !_recording)
          Positioned(
            top: 16,
            left: 16,
            right: 16,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_gpsError ?? 'Locating you…'),
              ),
            ),
          ),
        if (_recording)
          Positioned(
            top: 16,
            left: 16,
            right: 16,
            child: Card(
              color: theme.colorScheme.tertiaryContainer,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _recordStat(theme, _fmtDuration(_elapsed), 'time'),
                    _recordStat(theme, km, 'km'),
                    _recordStat(theme, '${_track.length}', 'points'),
                  ],
                ),
              ),
            ),
          ),
        if (_lastFix != null)
          Positioned(
            right: 16,
            bottom: 88,
            child: FloatingActionButton.small(
              heroTag: 'recenter',
              onPressed: _recenterOrAlignNorth,
              tooltip: showCompass ? 'Align north' : 'Recenter on me',
              child: showCompass
                  ? _CompassNeedle(bearingDeg: _mapRotation)
                  : const Icon(Icons.my_location),
            ),
          ),
        Positioned(
          left: 24,
          right: 24,
          bottom: 24,
          child: _recording
              ? FilledButton.icon(
                  onPressed: _stopRecording,
                  icon: const Icon(Icons.stop),
                  label: const Text('Stop & Save'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    backgroundColor: theme.colorScheme.error,
                    foregroundColor: theme.colorScheme.onError,
                  ),
                )
              : FilledButton.icon(
                  onPressed: _startRecording,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Start Run'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                  ),
                ),
        ),
      ],
    );
  }

  // A "you are here" dot for the map marker.
  Widget _locationDot(Color color) {
    return Container(
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 3),
      ),
    );
  }

  // Runs page: list of saved tracks, newest first. Tapping opens it on a map.
  Widget _buildRunsPage(ThemeData theme) {
    return FutureBuilder<List<_RunSummary>>(
      future: _runsFuture ?? _loadRuns(),
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
                'No recorded runs yet.\nRecord one on the Record tab.',
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
            return ListTile(
              leading: const Icon(Icons.route),
              title: Text(_fmtRunDate(r.start)),
              subtitle: Text('${r.km.toStringAsFixed(2)} km · '
                  '${_fmtDuration(r.duration)} · ${r.pointCount} pts'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _openRun(r),
              onLongPress: () => _confirmDeleteRun(r),
            );
          },
        );
      },
    );
  }

  Future<List<_RunSummary>> _loadRuns() async {
    final dir = await getApplicationDocumentsDirectory();
    final files = dir.listSync().whereType<File>().where((f) =>
        f.path.endsWith('.json') && f.path.contains('xc_route_'));
    final runs = <_RunSummary>[];
    for (final f in files) {
      try {
        final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        runs.add(_RunSummary(
          file: f,
          start: DateTime.parse(m['start_time'] as String),
          km: (m['distance_meters'] as num).toDouble() / 1000,
          duration: Duration(seconds: (m['duration_seconds'] as num).toInt()),
          pointCount: (m['point_count'] as num).toInt(),
        ));
      } catch (_) {
        // Skip malformed files.
      }
    }
    runs.sort((a, b) => b.start.compareTo(a.start)); // newest first
    return runs;
  }

  Future<void> _confirmDeleteRun(_RunSummary r) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this run?'),
        content: Text(
          '${_fmtRunDate(r.start)}\n'
          '${r.km.toStringAsFixed(2)} km · ${_fmtDuration(r.duration)} · '
          '${r.pointCount} points\n\nThis permanently deletes the saved track.',
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
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await r.file.delete();
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Could not delete run: $e');
      return;
    }
    if (!mounted) return;
    setState(() {
      _runsFuture = _loadRuns(); // refresh the list
    });
  }

  Future<void> _openRun(_RunSummary r) async {
    try {
      final m = jsonDecode(await r.file.readAsString()) as Map<String, dynamic>;
      final pts = [
        for (final p in (m['points'] as List))
          LatLng((p['lat'] as num).toDouble(), (p['lng'] as num).toDouble()),
      ];
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => _RunMapPage(
          title: _fmtRunDate(r.start),
          subtitle: '${r.km.toStringAsFixed(2)} km · '
              '${_fmtDuration(r.duration)} · ${r.pointCount} points',
          points: pts,
        ),
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Could not open run: $e');
    }
  }

  String _fmtRunDate(DateTime utc) {
    final d = utc.toLocal();
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final ampm = d.hour < 12 ? 'AM' : 'PM';
    final min = d.minute.toString().padLeft(2, '0');
    return '${months[d.month - 1]} ${d.day}, ${d.year}  $h:$min $ampm';
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
          // Independent of health permissions — just rewinds the sync watermark.
          debugButton(Icons.history, 'Reset Sync (-24h + routes)',
              _resetSyncWatermark),
          const SizedBox(height: 8),
          debugButton(Icons.route, 'Grant HC Route Access',
              _grantRouteAccess),
          const SizedBox(height: 8),
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
