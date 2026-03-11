import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:http/http.dart' as http;
import 'package:vibration/vibration.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const SpeedLimitApp());
}

class SpeedLimitApp extends StatelessWidget {
  const SpeedLimitApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SpeedLimit',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0A0A0A),
      ),
      home: const SpeedometerScreen(),
    );
  }
}

// ─────────────────────────────────────────────
//  DATA MODEL
// ─────────────────────────────────────────────
class SpeedData {
  final double speedKmh;
  final int? currentLimit;
  final int? nextLimit;
  final double? nextLimitDistanceM;
  final bool hasGps;

  const SpeedData({
    required this.speedKmh,
    this.currentLimit,
    this.nextLimit,
    this.nextLimitDistanceM,
    required this.hasGps,
  });

  bool get isOverLimit => currentLimit != null && speedKmh > currentLimit! + 3;
  bool get isNearLimit =>
      currentLimit != null &&
      speedKmh >= currentLimit! - 3 &&
      speedKmh <= currentLimit! + 3;

  Color get borderColor {
    if (!hasGps) return Colors.grey;
    if (isOverLimit) return const Color(0xFFFF2D2D);
    if (isNearLimit) return const Color(0xFFFFCC00);
    return const Color(0xFF00E676);
  }
}

// ─────────────────────────────────────────────
//  OVERPASS SERVICE
// ─────────────────────────────────────────────
class OverpassService {
  static const _mirrors = [
    'https://overpass.kumi.systems/api/interpreter',
    'https://overpass-api.de/api/interpreter',
  ];

  int? _cachedCurrentLimit;
  int? _cachedNextLimit;

  // Last positions where we did queries
  Position? _lastCurrentQueryPos;
  ({double lat, double lon})? _lastNextQueryPoint;

  /// Current limit — re-query every 15 m
  Future<int?> fetchCurrentLimit(double lat, double lon) async {
    if (_lastCurrentQueryPos != null) {
      final dist = Geolocator.distanceBetween(
          _lastCurrentQueryPos!.latitude, _lastCurrentQueryPos!.longitude,
          lat, lon);
      if (dist < 15) return _cachedCurrentLimit;
    }

    final query = '[out:json][timeout:5];way[maxspeed](around:20,$lat,$lon);out tags;';
    final result = await _query(query);
    if (result != null) {
      _cachedCurrentLimit = result;
      _lastCurrentQueryPos = _fakePos(lat, lon);
    }
    return _cachedCurrentLimit;
  }

  /// Next limit — look 200 m ahead, re-query every 30 m of movement
  Future<int?> fetchNextLimit(double lat, double lon, double heading, double speedKmh) async {
    // How far ahead to look: faster = look further
    final lookAheadM = speedKmh > 80 ? 400.0 : speedKmh > 50 ? 300.0 : 200.0;
    final ahead = _pointAhead(lat, lon, heading, lookAheadM);

    if (_lastNextQueryPoint != null) {
      final dist = Geolocator.distanceBetween(
          _lastNextQueryPoint!.lat, _lastNextQueryPoint!.lon,
          ahead.lat, ahead.lon);
      if (dist < 30) return _cachedNextLimit;
    }

    final query = '[out:json][timeout:5];way[maxspeed](around:25,${ahead.lat},${ahead.lon});out tags;';
    final result = await _query(query);
    _cachedNextLimit = result;
    _lastNextQueryPoint = ahead;
    return _cachedNextLimit;
  }

  Future<int?> _query(String query) async {
    for (final mirror in _mirrors) {
      try {
        final uri = Uri.parse(mirror).replace(queryParameters: {'data': query});
        final resp = await http.get(uri).timeout(const Duration(seconds: 6));
        if (resp.statusCode == 200) {
          return _parseMaxspeed(resp.body);
        }
      } catch (_) {}
    }
    return null;
  }

  int? _parseMaxspeed(String body) {
    try {
      final data = jsonDecode(body) as Map<String, dynamic>;
      final elements = data['elements'] as List<dynamic>? ?? [];
      for (final el in elements) {
        final tags = el['tags'] as Map<String, dynamic>? ?? {};
        final raw = tags['maxspeed']?.toString() ?? '';
        final parsed = _parseSpeedString(raw);
        if (parsed != null) return parsed;
      }
    } catch (_) {}
    return null;
  }

  int? _parseSpeedString(String raw) {
    if (raw.isEmpty) return null;
    final zones = {
      'ru:urban': 60, 'ru:rural': 90, 'ru:motorway': 110,
      'de:urban': 50, 'de:rural': 100, 'de:motorway': 130,
      'living_street': 20, 'walk': 10, 'none': 130,
    };
    final lower = raw.toLowerCase().replaceAll(' ', '');
    for (final e in zones.entries) {
      if (lower.contains(e.key)) return e.value;
    }
    final match = RegExp(r'(\d+)').firstMatch(raw);
    if (match == null) return null;
    int val = int.parse(match.group(1)!);
    if (raw.toLowerCase().contains('mph')) val = (val * 1.60934).round();
    return val;
  }

  ({double lat, double lon}) _pointAhead(
      double lat, double lon, double heading, double distM) {
    const earthR = 6371000.0;
    final d = distM / earthR;
    final h = heading * pi / 180;
    final lat1 = lat * pi / 180;
    final lon1 = lon * pi / 180;
    final lat2 = asin(sin(lat1) * cos(d) + cos(lat1) * sin(d) * cos(h));
    final lon2 = lon1 +
        atan2(sin(h) * sin(d) * cos(lat1), cos(d) - sin(lat1) * sin(lat2));
    return (lat: lat2 * 180 / pi, lon: lon2 * 180 / pi);
  }

  Position _fakePos(double lat, double lon) => Position(
        latitude: lat, longitude: lon, timestamp: DateTime.now(),
        accuracy: 0, altitude: 0, altitudeAccuracy: 0,
        heading: 0, headingAccuracy: 0, speed: 0, speedAccuracy: 0,
      );
}

// ─────────────────────────────────────────────
//  MAIN SCREEN
// ─────────────────────────────────────────────
class SpeedometerScreen extends StatefulWidget {
  const SpeedometerScreen({super.key});
  @override
  State<SpeedometerScreen> createState() => _SpeedometerScreenState();
}

class _SpeedometerScreenState extends State<SpeedometerScreen>
    with TickerProviderStateMixin {
  final _overpass = OverpassService();
  SpeedData _data = const SpeedData(speedKmh: 0, hasGps: false);
  StreamSubscription<Position>? _posStream;
  bool _permissionDenied = false;
  bool _wasOverLimit = false;

  late AnimationController _pulseController;
  late Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    )..addStatusListener((s) {
        if (s == AnimationStatus.completed) _pulseController.reverse();
      });
    _pulseAnim = Tween<double>(begin: 1.0, end: 1.04)
        .animate(CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut));
    _requestAndStart();
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    _posStream?.cancel();
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _requestAndStart() async {
    var status = await Permission.locationWhenInUse.request();
    if (status.isDenied || status.isPermanentlyDenied) {
      setState(() => _permissionDenied = true);
      return;
    }
    _startTracking();
  }

  void _startTracking() {
    // distanceFilter: 0 — получаем каждое обновление GPS без фильтрации
    const settings = LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 0,
    );
    _posStream = Geolocator.getPositionStream(locationSettings: settings)
        .listen(_onPosition, onError: (_) {
      setState(() {
        _data = SpeedData(speedKmh: _data.speedKmh,
            currentLimit: _data.currentLimit, hasGps: false);
      });
    });
  }

  Future<void> _onPosition(Position pos) async {
    final speedKmh = pos.speed < 0 ? 0.0 : pos.speed * 3.6;
    final isMoving = speedKmh > 3;

    // Запрашиваем текущий и следующий лимит параллельно
    final currentFuture = _overpass.fetchCurrentLimit(pos.latitude, pos.longitude);
    final nextFuture = isMoving
        ? _overpass.fetchNextLimit(pos.latitude, pos.longitude, pos.heading, speedKmh)
        : Future.value(null);

    final results = await Future.wait([currentFuture, nextFuture]);
    final currentLimit = results[0];
    final nextLimit = results[1];

    // Считаем реальное расстояние до точки впереди
    final lookAheadM = speedKmh > 80 ? 400.0 : speedKmh > 50 ? 300.0 : 200.0;

    // Показываем следующий лимит только если он отличается от текущего
    final showNext = isMoving &&
        nextLimit != null &&
        nextLimit != currentLimit;

    final newData = SpeedData(
      speedKmh: speedKmh,
      currentLimit: currentLimit,
      nextLimit: showNext ? nextLimit : null,
      nextLimitDistanceM: showNext ? lookAheadM : null,
      hasGps: true,
    );

    if (newData.isOverLimit && !_wasOverLimit) _triggerAlert();
    _wasOverLimit = newData.isOverLimit;

    if (mounted) setState(() => _data = newData);
  }

  void _triggerAlert() {
    _pulseController.forward(from: 0);
    Vibration.hasVibrator().then((has) {
      if (has == true) Vibration.vibrate(duration: 400, amplitude: 200);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_permissionDenied) return _buildPermissionScreen();
    return _buildSpeedometer();
  }

  Widget _buildSpeedometer() {
    final speed = _data.speedKmh.round();
    final border = _data.borderColor;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      body: AnimatedBuilder(
        animation: _pulseAnim,
        builder: (context, child) => Transform.scale(
          scale: _data.isOverLimit ? _pulseAnim.value : 1.0,
          child: child,
        ),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          // FIX 1: толстая рамка на весь экран
          decoration: BoxDecoration(
            border: Border.all(color: border, width: 12),
          ),
          child: SafeArea(
            child: Column(
              children: [
                // GPS индикатор
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _GpsIndicator(hasGps: _data.hasGps),
                      const Text('SPEEDLIMIT',
                          style: TextStyle(
                              color: Colors.white24,
                              fontSize: 12,
                              letterSpacing: 3)),
                      const SizedBox(width: 50),
                    ],
                  ),
                ),

                const Spacer(),

                // Большая цифра скорости
                AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 150),
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 150,
                    fontWeight: FontWeight.w900,
                    color: _data.isOverLimit
                        ? const Color(0xFFFF2D2D)
                        : Colors.white,
                    height: 1,
                  ),
                  child: Text('$speed'),
                ),
                const Text('КМ/Ч',
                    style: TextStyle(
                        color: Colors.white38,
                        fontSize: 16,
                        letterSpacing: 6,
                        fontWeight: FontWeight.w300)),

                const Spacer(),

                // Текущий лимит
                _LimitBadge(
                    limit: _data.currentLimit, isOver: _data.isOverLimit),

                const SizedBox(height: 20),

                // FIX 2: следующий лимит — крупнее
                SizedBox(
                  height: 90,
                  child: _data.nextLimit != null
                      ? _NextLimitRow(
                          nextLimit: _data.nextLimit!,
                          distanceM: _data.nextLimitDistanceM ?? 300,
                        )
                      : const SizedBox(),
                ),

                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPermissionScreen() {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.location_off, color: Colors.white38, size: 64),
              const SizedBox(height: 24),
              const Text('Нужен доступ к геолокации',
                  style: TextStyle(color: Colors.white, fontSize: 22),
                  textAlign: TextAlign.center),
              const SizedBox(height: 12),
              const Text(
                  'Приложение использует GPS для определения скорости и ограничений на дороге.',
                  style: TextStyle(color: Colors.white54, fontSize: 15),
                  textAlign: TextAlign.center),
              const SizedBox(height: 32),
              ElevatedButton(
                onPressed: () async {
                  await openAppSettings();
                  setState(() => _permissionDenied = false);
                  _requestAndStart();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00E676),
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('Открыть настройки',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  WIDGETS
// ─────────────────────────────────────────────

class _GpsIndicator extends StatelessWidget {
  final bool hasGps;
  const _GpsIndicator({required this.hasGps});
  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Container(
        width: 8, height: 8,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: hasGps ? const Color(0xFF00E676) : Colors.red,
        ),
      ),
      const SizedBox(width: 6),
      Text(hasGps ? 'GPS' : 'Нет GPS',
          style: TextStyle(
              color: hasGps ? Colors.white38 : Colors.red,
              fontSize: 12,
              letterSpacing: 1)),
    ]);
  }
}

class _LimitBadge extends StatelessWidget {
  final int? limit;
  final bool isOver;
  const _LimitBadge({this.limit, required this.isOver});
  @override
  Widget build(BuildContext context) {
    if (limit == null) {
      return Container(
        width: 110, height: 110,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white24, width: 4),
        ),
        child: const Center(
            child: Text('—',
                style: TextStyle(color: Colors.white38, fontSize: 32))),
      );
    }
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      width: 110, height: 110,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white,
        border: Border.all(
          color: isOver ? const Color(0xFFFF2D2D) : const Color(0xFF222222),
          width: 5,
        ),
        boxShadow: isOver
            ? [BoxShadow(
                color: Colors.red.withOpacity(0.6),
                blurRadius: 24, spreadRadius: 6)]
            : null,
      ),
      child: Center(
        child: Text('$limit',
            style: TextStyle(
              color: isOver ? Colors.red.shade800 : Colors.black,
              fontSize: limit! >= 100 ? 30 : 36,
              fontWeight: FontWeight.w900,
              height: 1,
            )),
      ),
    );
  }
}

class _NextLimitRow extends StatelessWidget {
  final int nextLimit;
  final double distanceM;
  const _NextLimitRow({required this.nextLimit, required this.distanceM});
  @override
  Widget build(BuildContext context) {
    final dist = distanceM < 1000
        ? '${distanceM.round()} м'
        : '${(distanceM / 1000).toStringAsFixed(1)} км';
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12, width: 1),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.arrow_forward,
              color: Colors.white54, size: 22),
          const SizedBox(width: 10),
          // FIX 2: крупный текст расстояния
          Text('Через $dist',
              style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 20,
                  fontWeight: FontWeight.w500)),
          const SizedBox(width: 14),
          // Крупный знак следующего лимита
          Container(
            width: 56, height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white,
              border: Border.all(color: Colors.black26, width: 2),
            ),
            child: Center(
              child: Text('$nextLimit',
                  style: TextStyle(
                    color: Colors.black,
                    fontWeight: FontWeight.w900,
                    fontSize: nextLimit >= 100 ? 16 : 20,
                  )),
            ),
          ),
        ],
      ),
    );
  }
}
