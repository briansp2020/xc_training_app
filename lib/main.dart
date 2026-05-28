import 'package:flutter/material.dart';
import 'package:health/health.dart';

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

  String _status = 'Not connected to Health Connect yet.';
  bool _permissionsGranted = false;
  String? _heartRateValue;
  String? _heartRateTime;

  final List<HealthDataType> _types = [
    HealthDataType.HEART_RATE,
    HealthDataType.STEPS,
    HealthDataType.DISTANCE_DELTA,
    HealthDataType.SLEEP_ASLEEP,
    HealthDataType.ACTIVE_ENERGY_BURNED,
  ];

  Future<void> _requestPermissions() async {
    setState(() => _status = 'Requesting permissions...');

    try {
      final requested = await _health.requestAuthorization(
        _types,
        permissions: _types.map((_) => HealthDataAccess.READ).toList(),
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

  Future<void> _readHeartRate() async {
    if (!_permissionsGranted) {
      setState(() => _status = 'Please request permissions first.');
      return;
    }

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
            FilledButton.icon(
              onPressed: _requestPermissions,
              icon: const Icon(Icons.lock_open),
              label: const Text('Request Permissions'),
            ),
            const SizedBox(height: 12),
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
