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
//  OVERPASS SERVICE  (работает в фоне, не блокирует UI)
// ─────────────────────────────────────────────
class OverpassService {
  static const _mirrors = [
    'https://overpass.kumi.systems/api/interpreter',
    'https://overpass-api.de/api/interpreter',
  ];

  int? cachedCurrentLimit;
  int? cachedNextLimit;

  double? _lastCurrentLat, _lastCurrentLon;
  double? _lastNextLat, _lastNextLon;

  bool _fetchingCurrent = false;
  bool _fetchingNext = false;

  // Запрашиваем только если сдвинулись на 15+ м — не блокируем UI
  void fetchCurrentIfNeeded(double lat, double lon) {
    if (_fetchingCurrent) return;
    if (_lastCurrentLat != null) {
      final d = Geolocator.distanceBetween(_lastCurrentLat!, _lastCurrentLon!, lat, lon);
      if (d < 15) return;
    }
    _fetchingCurrent = true;
    _lastCurrentLat = lat;
    _lastCurrentLon = lon;
    _doQuery('[out:json][timeout:5];way[maxspeed](around:20,$lat,$lon);out tags;')
        .then((v) {
      if (v != null) cachedCurrentLimit = v;
      _fetchingCurrent = false;
    });
  }

  void fetchNextIfNeeded(double lat, double lon, double heading, double speedKmh) {
    if (_fetchingNext) return;
    final lookM = speedKmh > 80 ? 450.0 : speedKmh > 50 ? 320.0 : 220.0;
    final ahead = _pointAhead(lat, lon, heading, lookM);
    if (_lastNextLat != null) {
      final d = Geolocator.distanceBetween(_lastNextLat!, _lastNextLon!, ahead.lat, ahead.lon);
      if (d < 25) return;
    }
    _fetchingNext = true;
    _lastNextLat = ahead.lat;
    _lastNextLon = ahead.lon;
    _doQuery('[out:json][timeout:5];way[maxspeed](around:25,${ahead.lat},${ahead.lon});out tags;')
        .then((v) {
      cachedNextLimit = v;
      _fetchingNext = false;
    });
  }

  Future<int?> _doQuery(String query) async {
    for (final mirror in _mirrors) {
      try {
        final uri = Uri.parse(mirror).replace(queryParameters: {'data': query});
        final resp = await http.get(uri).timeout(const Duration(seconds: 7));
        if (resp.statusCode == 200) return _parse(resp.body);
      } catch (_) {}
    }
    return null;
  }

  int? _parse(String body) {
    try {
      final data = jsonDecode(body) as Map<String, dynamic>;
      final elements = data['elements'] as List<dynamic>? ?? [];
      for (final el in elements) {
        final tags = el['tags'] as Map<String, dynamic>? ?? {};
        final raw = tags['maxspeed']?.toString() ?? '';
        final v = _parseSpeed(raw);
        if (v != null) return v;
      }
    } catch (_) {}
    return null;
  }

  int? _parseSpeed(String raw) {
    if (raw.isEmpty) return null;
    const zones = {
      'ru:urban': 60, 'ru:rural': 90, 'ru:motorway': 110,
      'de:urban': 50, 'de:rural': 100, 'de:motorway': 130,
      'living_street': 20, 'walk': 10, 'none': 130,
    };
    final lower = raw.toLowerCase().replaceAll(' ', '');
    for (final e in zones.entries) {
      if (lower.contains(e.key)) return e.value;
    }
    final m = RegExp(r'(\d+)').firstMatch(raw);
    if (m == null) return null;
    int val = int.parse(m.group(1)!);
    if (raw.toLowerCase().contains('mph')) val = (val * 1.60934).round();
    return val;
  }

  ({double lat, double lon}) _pointAhead(
      double lat, double lon, double heading, double distM) {
    const R = 6371000.0;
    final d = distM / R;
    final h = heading * pi / 180;
    final lat1 = lat * pi / 180;
    final lon1 = lon * pi / 180;
    final lat2 = asin(sin(lat1) * cos(d) + cos(lat1) * sin(d) * cos(h));
    final lon2 = lon1 + atan2(sin(h) * sin(d) * cos(lat1), cos(d) - sin(lat1) * sin(lat2));
    return (lat: lat2 * 180 / pi, lon: lon2 * 180 / pi);
  }
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

  // Скорость обновляется МГНОВЕННО из GPS — отдельно от лимитов
  double _speedKmh = 0;
  bool _hasGps = false;
  bool _wasOverLimit = false;

  // Плашка "следующий лимит" — держим минимум 5 секунд
  int? _nextLimit;
  double? _nextLimitDist;
  Timer? _nextLimitHideTimer;

  late AnimationController _pulseController;
  late Animation<double> _pulseAnim;
  StreamSubscription<Position>? _posStream;
  bool _permissionDenied = false;

  bool get _isOverLimit =>
      _overpass.cachedCurrentLimit != null &&
      _speedKmh > _overpass.cachedCurrentLimit! + 3;

  bool get _isNearLimit =>
      _overpass.cachedCurrentLimit != null &&
      _speedKmh >= _overpass.cachedCurrentLimit! - 3 &&
      _speedKmh <= _overpass.cachedCurrentLimit! + 3;

  Color get _borderColor {
    if (!_hasGps) return Colors.grey;
    if (_isOverLimit) return const Color(0xFFFF2D2D);
    if (_isNearLimit) return const Color(0xFFFFCC00);
    return const Color(0xFF00E676);
  }

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
    _nextLimitHideTimer?.cancel();
    super.dispose();
  }

  Future<void> _requestAndStart() async {
    final status = await Permission.locationWhenInUse.request();
    if (status.isDenied || status.isPermanentlyDenied) {
      setState(() => _permissionDenied = true);
      return;
    }
    _startTracking();
  }

  void _startTracking() {
    // distanceFilter: 0 + bestForNavigation = максимальная частота GPS
    const settings = LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 0,
    );
    _posStream = Geolocator.getPositionStream(locationSettings: settings)
        .listen(_onPosition);
  }

  void _onPosition(Position pos) {
    // ── 1. СКОРОСТЬ — обновляем СРАЗУ, без await ──
    final kmh = pos.speed < 0 ? 0.0 : pos.speed * 3.6;
    final isMoving = kmh > 3;

    // ── 2. Лимиты — запускаем в фоне, НЕ ждём ──
    _overpass.fetchCurrentIfNeeded(pos.latitude, pos.longitude);
    if (isMoving) {
      _overpass.fetchNextIfNeeded(
          pos.latitude, pos.longitude, pos.heading, kmh);
    }

    // ── 3. Обновляем плашку "следующий" ──
    final newNext = _overpass.cachedNextLimit;
    final currentLimit = _overpass.cachedCurrentLimit;
    final showNext = isMoving && newNext != null && newNext != currentLimit;

    if (showNext && newNext != _nextLimit) {
      // Новый лимит впереди — показываем и сбрасываем таймер скрытия
      _nextLimitHideTimer?.cancel();
      _nextLimit = newNext;
      _nextLimitDist = kmh > 80 ? 450.0 : kmh > 50 ? 320.0 : 220.0;
      // Держим плашку минимум 6 секунд
      _nextLimitHideTimer = Timer(const Duration(seconds: 6), () {
        if (mounted) setState(() { _nextLimit = null; _nextLimitDist = null; });
      });
    }

    // Алерт превышения
    final over = currentLimit != null && kmh > currentLimit + 3;
    if (over && !_wasOverLimit) _triggerAlert();
    _wasOverLimit = over;

    if (mounted) {
      setState(() {
        _speedKmh = kmh;
        _hasGps = true;
      });
    }
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

    final speed = _speedKmh.round();
    final border = _borderColor;
    final currentLimit = _overpass.cachedCurrentLimit;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      body: AnimatedBuilder(
        animation: _pulseAnim,
        builder: (ctx, child) => Transform.scale(
          scale: _isOverLimit ? _pulseAnim.value : 1.0,
          child: child,
        ),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            // FIX: толстая рамка 14px
            border: Border.all(color: border, width: 14),
          ),
          child: SafeArea(
            child: Column(
              children: [
                // GPS бейдж
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _GpsIndicator(hasGps: _hasGps),
                      const Text('SPEEDLIMIT',
                          style: TextStyle(color: Colors.white24, fontSize: 12, letterSpacing: 3)),
                      const SizedBox(width: 50),
                    ],
                  ),
                ),

                const Spacer(),

                // Большая скорость
                AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 80), // быстрая анимация
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 160,
                    fontWeight: FontWeight.w900,
                    color: _isOverLimit ? const Color(0xFFFF2D2D) : Colors.white,
                    height: 1,
                  ),
                  child: Text('$speed'),
                ),
                const Text('КМ/Ч',
                    style: TextStyle(
                        color: Colors.white38, fontSize: 16,
                        letterSpacing: 6, fontWeight: FontWeight.w300)),

                const Spacer(),

                // Текущий лимит (знак)
                _LimitBadge(limit: currentLimit, isOver: _isOverLimit),

                const SizedBox(height: 16),

                // Следующий лимит — крупная плашка, минимум 6 сек видна
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 400),
                  child: _nextLimit != null
                      ? _NextLimitBanner(
                          key: ValueKey(_nextLimit),
                          nextLimit: _nextLimit!,
                          distanceM: _nextLimitDist ?? 300,
                        )
                      : const SizedBox(height: 88),
                ),

                const SizedBox(height: 24),
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
              const Text('Приложение использует GPS для определения скорости и ограничений.',
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
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
            color: hasGps ? const Color(0xFF00E676) : Colors.red),
      ),
      const SizedBox(width: 6),
      Text(hasGps ? 'GPS' : 'Нет GPS',
          style: TextStyle(
              color: hasGps ? Colors.white38 : Colors.red,
              fontSize: 12, letterSpacing: 1)),
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
            border: Border.all(color: Colors.white24, width: 4)),
        child: const Center(
            child: Text('—', style: TextStyle(color: Colors.white38, fontSize: 32))),
      );
    }
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: 110, height: 110,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white,
        border: Border.all(
            color: isOver ? const Color(0xFFFF2D2D) : const Color(0xFF222222),
            width: 5),
        boxShadow: isOver
            ? [BoxShadow(color: Colors.red.withOpacity(0.6), blurRadius: 24, spreadRadius: 6)]
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

// FIX: крупная плашка следующего лимита
class _NextLimitBanner extends StatelessWidget {
  final int nextLimit;
  final double distanceM;
  const _NextLimitBanner({super.key, required this.nextLimit, required this.distanceM});

  @override
  Widget build(BuildContext context) {
    final dist = distanceM < 1000
        ? '${distanceM.round()} м'
        : '${(distanceM / 1000).toStringAsFixed(1)} км';

    return Container(
      height: 88,
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.10),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white24, width: 1.5),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.arrow_forward_rounded, color: Colors.white60, size: 28),
          const SizedBox(width: 12),
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('СЛЕДУЮЩИЙ ЛИМИТ',
                  style: TextStyle(
                      color: Colors.white38, fontSize: 11, letterSpacing: 2)),
              const SizedBox(height: 2),
              Text('через $dist',
                  style: const TextStyle(
                      color: Colors.white, fontSize: 22, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(width: 16),
          // Большой знак следующего лимита
          Container(
            width: 64, height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white,
              border: Border.all(color: Colors.black26, width: 3),
            ),
            child: Center(
              child: Text('$nextLimit',
                  style: TextStyle(
                    color: Colors.black,
                    fontWeight: FontWeight.w900,
                    fontSize: nextLimit >= 100 ? 18 : 24,
                  )),
            ),
          ),
        ],
      ),
    );
  }
}
