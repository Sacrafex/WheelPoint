import 'dart:async';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:share_plus/share_plus.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Wheelpoint',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const MyHomePage(title: 'Flutter Demo Home Page'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});
  final String title;
  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  bool _isRiding = false;
  double _speed = 0.0; // Always in mph
  double _distance = 0.0;
  DateTime? _rideStart;
  DateTime? _rideEnd;
  List<LatLng> _route = [];

  Position? _currentPosition;
  String _vehicle = 'Bicycle';
  final List<String> _vehicles = ['Bicycle', 'Motorcycle', 'Car', 'E bike', 'Scooter'];
  double _maxSpeed = 0.0; // Always in mph
  double _avgSpeed = 0.0; // Always in mph
  bool _locationLoading = true;

  double _mapZoom = 16;
  final MapController _mapController = MapController();
  Timer? _updateTimer;
  StreamSubscription<Position>? _positionStream;

  // For GPS-based speed estimation
  double _lastGpsSpeed = 0.0; // mph
  double _lastAcceleration = 0.0;
  DateTime? _lastSpeedUpdate;
  // Add for smoothing
  List<double> _speedSamples = [];
  final int _speedSmoothingWindow = 8; // More smoothing
  DateTime? _lastPositionUpdate;
  bool _dotStale = false;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
    ]);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _requestLocationPermission();
    });
    _fetchInitialLocation();
    _startLocationUpdates();
    _startFrameUpdates();
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    _positionStream?.cancel();
    super.dispose();
  }

  void _startFrameUpdates() {
    _updateTimer?.cancel();
    _updateTimer = Timer.periodic(const Duration(milliseconds: 500), (_) async {
      if (!mounted) return;
      try {
        final pos = await Geolocator.getCurrentPosition(locationSettings: LocationSettings(accuracy: LocationAccuracy.best));
        setState(() {
          final prev = _currentPosition;
          _currentPosition = pos;
          final newLatLng = LatLng(pos.latitude, pos.longitude);
          DateTime? prevTime = prev?.timestamp;
          DateTime? newTime = pos.timestamp;
          double gpsSpeed = 0.0;
          if (prevTime != null) {
            final dt = newTime.difference(prevTime).inMilliseconds / 1000.0;
            if (dt > 0.1 && dt < 10) {
              final d = Geolocator.distanceBetween(
                prev!.latitude, prev.longitude,
                pos.latitude, pos.longitude,
              );
              gpsSpeed = d / dt; // m/s
            }
          }
          // Fallback to position's speed if available
          if (gpsSpeed == 0.0 && pos.speed > 0) {
            gpsSpeed = pos.speed;
          }
          // Convert to mph
          gpsSpeed *= 2.23694;
          // Smoothing: moving average, clamp spikes
          if (_speedSamples.isNotEmpty && (gpsSpeed - _speedSamples.last).abs() > 20) {
            gpsSpeed = _speedSamples.last; // ignore spike
          }
          _speedSamples.add(gpsSpeed);
          if (_speedSamples.length > _speedSmoothingWindow) {
            _speedSamples.removeAt(0);
          }
          double smoothedSpeed = _speedSamples.reduce((a, b) => a + b) / _speedSamples.length;
          // Clamp low speeds to 0 if < 3 mph
          if (smoothedSpeed < 3) smoothedSpeed = 0;
          // Calculate acceleration (mph/s)
          final now = DateTime.now();
          double acceleration = 0.0;
          if (_lastSpeedUpdate != null) {
            final dt = now.difference(_lastSpeedUpdate!).inMilliseconds / 1000.0;
            if (dt > 0.05) {
              acceleration = (smoothedSpeed - _lastGpsSpeed) / dt;
            }
          }
          _lastSpeedUpdate = now;
          _lastAcceleration = acceleration;
          _lastGpsSpeed = smoothedSpeed;
          _speed = smoothedSpeed;
          // Path tracking: always add new point if moved > 2m, but only while riding
          if (_isRiding && (_route.isEmpty || Geolocator.distanceBetween(_route.last.latitude, _route.last.longitude, newLatLng.latitude, newLatLng.longitude) > 2)) {
            _route.add(newLatLng);
          }
          // Only update max, avg, distance while riding
          if (_isRiding) {
            if (_speed > _maxSpeed) _maxSpeed = _speed;
            // Calculate distance only from _route points (sum all segments)
            double totalDist = 0.0;
            for (int i = 1; i < _route.length; i++) {
              totalDist += Geolocator.distanceBetween(
                _route[i - 1].latitude,
                _route[i - 1].longitude,
                _route[i].latitude,
                _route[i].longitude,
              );
            }
            _distance = totalDist;
            // Update avg speed (mph)
            if (_rideStart != null) {
              final elapsed = DateTime.now().difference(_rideStart!).inSeconds;
              _avgSpeed = (elapsed > 0 && _distance > 0) ? (_distance * 0.000621371) / (elapsed / 3600.0) : 0.0;
            }
            if (_currentPosition != null) {
              final latLng = LatLng(_currentPosition!.latitude, _currentPosition!.longitude);
              _mapController.move(latLng, _mapZoom);
            }
          }
          _lastPositionUpdate = now;
          _dotStale = false;
        });
      } catch (_) {}
    });
    // Timer to check for stale dot
    Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_lastPositionUpdate == null) return;
      final now = DateTime.now();
      if (now.difference(_lastPositionUpdate!).inSeconds > 3) {
        if (!_dotStale) setState(() { _dotStale = true; });
      } else {
        if (_dotStale) setState(() { _dotStale = false; });
      }
    });
  }

  Future<void> _requestLocationPermission() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever ||
        permission == LocationPermission.unableToDetermine) {
      permission = await Geolocator.requestPermission();
    }
    if (permission != LocationPermission.always && permission != LocationPermission.whileInUse) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Precise location permission is required. Please enable it in settings.')));
    }
  }

  Future<void> _fetchInitialLocation() async {
    setState(() { _locationLoading = true; });
    try {
      _currentPosition = await Geolocator.getCurrentPosition(locationSettings: const LocationSettings(accuracy: LocationAccuracy.best));
      _route = [LatLng(_currentPosition!.latitude, _currentPosition!.longitude)];
    } catch (e) {/* ignore */}
    setState(() { _locationLoading = false; });
  }

  void _startLocationUpdates() {
    _positionStream?.cancel();
    _positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 0,
        timeLimit: null,
      ),
    ).listen((Position position) {
      setState(() {
        _currentPosition = position;
      });
    });
  }

  void _toggleRide() async {
    if (!_isRiding) {
      LocationPermission permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Location permission is required.')));
        return;
      }
      _rideStart = DateTime.now();
      _rideEnd = null;
      _distance = 0.0;
      _speed = 0.0;
      _maxSpeed = 0.0;
      _avgSpeed = 0.0;
      _route = [];
      _currentPosition = await Geolocator.getCurrentPosition(locationSettings: const LocationSettings(accuracy: LocationAccuracy.best));
      _route.add(LatLng(_currentPosition!.latitude, _currentPosition!.longitude));
    } else {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('End Ride?'),
          content: const Text('Are you sure you want to end your ride?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('End Ride'),
            ),
          ],
        ),
      );
      if (confirm != true) return;
      setState(() {
        _rideEnd = DateTime.now();
      });
      Future.delayed(Duration.zero, () {
        if (!mounted) return;
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: Colors.black87,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Ride Finished!', style: TextStyle(color: const Color(0xFF00bcd4), fontSize: 22, fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00bcd4),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                  ),
                  icon: const Icon(Icons.share),
                  label: const Text('Share Ride'),
                  onPressed: _shareRideStats,
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text('Close', style: TextStyle(color: const Color(0xFF00bcd4))),
              ),
            ],
          ),
        );
      });
    }
    setState(() {
      _isRiding = !_isRiding;
    });
  }

  void _toggleVehicle() {
    setState(() {
      int idx = _vehicles.indexOf(_vehicle);
      _vehicle = _vehicles[(idx + 1) % _vehicles.length];
    });
  }

  void _shareRideStats() {
    final info = 'Wheelpoint Ride\n'
        'Duration: ${_formatDuration((_rideEnd ?? DateTime.now()).difference(_rideStart ?? DateTime.now()))}\n'
        'Distance: ${(_distance * 0.000621371).toStringAsFixed(2)} mi\n'
        'Max Speed: ${_maxSpeed.toStringAsFixed(1)} mph\n'
        'Avg Speed: ${_avgSpeed.toStringAsFixed(1)} mph';
    Share.share(info, subject: 'My Wheelpoint Ride');
  }

  @override
  Widget build(BuildContext context) {
    final darkCyan = const Color(0xFF00bcd4);
    final bgDark = const Color(0xFF121212);
    final speed = _speed.round(); // mph, no decimals
    final speedUnit = 'mph';
    final maxSpeed = _maxSpeed > 0 ? _maxSpeed : 1.0;
    final barValue = (speed / maxSpeed).clamp(0.0, 1.0);
    final accSign = _lastAcceleration > 0.2 ? '+' : _lastAcceleration < -0.2 ? '-' : '';
    final distance = _distance * 0.000621371;
    final distanceUnit = 'mi';
    final duration = _rideStart != null ? ((_rideEnd ?? DateTime.now()).difference(_rideStart!)) : Duration.zero;
    final LatLng? currentLatLng = _currentPosition != null ? LatLng(_currentPosition!.latitude, _currentPosition!.longitude) : null;

    if (_locationLoading) {
      return Scaffold(
        backgroundColor: bgDark,
        appBar: AppBar(
          backgroundColor: darkCyan,
          title: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.directions_bike, color: darkCyan, size: 28),
              const SizedBox(width: 8),
              const Text('Wheelpoint', style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
            ],
          ),
          centerTitle: true,
          elevation: 4,
        ),
        body: const Center(
          child: CircularProgressIndicator(color: Color(0xFF00bcd4)),
        ),
      );
    }

    return Scaffold(
      backgroundColor: bgDark,
      appBar: AppBar(
        backgroundColor: darkCyan,
        title: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('Wheelpoint', style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
          ],
        ),
        centerTitle: true,
        elevation: 4,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(
                      width: 120,
                      height: 120,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.black54,
                        border: Border.all(color: darkCyan, width: 4),
                      ),
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          SizedBox(
                            width: 120,
                            height: 120,
                            child: CircularProgressIndicator(
                              value: barValue,
                              backgroundColor: Colors.black26,
                              valueColor: AlwaysStoppedAnimation<Color>(darkCyan),
                              strokeWidth: 10,
                            ),
                          ),
                          Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(
                                    speed.toString(),
                                    style: TextStyle(fontSize: 48, color: darkCyan, fontWeight: FontWeight.bold),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.only(left: 2, bottom: 8),
                                    child: Text(
                                      accSign,
                                      style: TextStyle(
                                        fontSize: 28,
                                        color: accSign == '+' ? Colors.green : accSign == '-' ? Colors.red : Colors.grey,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              Padding(
                                padding: const EdgeInsets.only(top: 8.0),
                                child: Text(
                                  speedUnit,
                                  style: TextStyle(color: darkCyan, fontSize: 18, fontWeight: FontWeight.w600),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            Center(
              child: GestureDetector(
                onTap: _toggleVehicle,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: darkCyan, width: 2),
                  ),
                  child: Text(_vehicle, style: TextStyle(color: darkCyan, fontSize: 18)),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: Stack(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: FlutterMap(
                            mapController: _mapController,
                            options: MapOptions(
                              initialCenter: currentLatLng ?? LatLng(37.7749, -122.4194),
                              initialZoom: _mapZoom,
                              interactionOptions: const InteractionOptions(
                                flags: InteractiveFlag.pinchZoom | InteractiveFlag.drag,
                              ),
                              backgroundColor: const Color(0xFF181A1B),
                              onPositionChanged: (pos, hasGesture) {
                                setState(() {
                                  _mapZoom = pos.zoom;
                                });
                              },
                            ),
                            children: [
                              TileLayer(
                                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                                userAgentPackageName: 'com.example.wheelpoint',
                                retinaMode: true,
                              ),
                              // PolylineLayer for speed-based color per segment
                              if (_route.length > 1)
                                PolylineLayer(
                                  polylines: [
                                    Polyline(
                                      points: _route,
                                      color: Colors.blueAccent,
                                      strokeWidth: 5,
                                    ),
                                  ],
                                ),
                              Positioned(
                                top: 12,
                                right: 12,
                                child: Column(
                                  children: [
                                    FloatingActionButton(
                                      heroTag: 'align',
                                      mini: true,
                                      backgroundColor: darkCyan,
                                      child: const Icon(Icons.my_location, color: Colors.white),
                                      onPressed: () {
                                        if (currentLatLng != null) {
                                          _mapController.move(currentLatLng, _mapZoom);
                                        }
                                      },
                                    ),
                                    const SizedBox(height: 8),
                                    FloatingActionButton(
                                      heroTag: 'zoom_in',
                                      mini: true,
                                      backgroundColor: darkCyan,
                                      child: const Icon(Icons.zoom_in, color: Colors.white),
                                      onPressed: () {
                                        setState(() {
                                          _mapZoom += 1;
                                          if (currentLatLng != null) {
                                            _mapController.move(currentLatLng, _mapZoom);
                                          }
                                        });
                                      },
                                    ),
                                    const SizedBox(height: 8),
                                    FloatingActionButton(
                                      heroTag: 'zoom_out',
                                      mini: true,
                                      backgroundColor: darkCyan,
                                      child: const Icon(Icons.zoom_out, color: Colors.white),
                                      onPressed: () {
                                        setState(() {
                                          _mapZoom -= 1;
                                          if (currentLatLng != null) {
                                            _mapController.move(currentLatLng, _mapZoom);
                                          }
                                        });
                                      },
                                    ),
                                  ],
                                ),
                              ),
                              if (currentLatLng != null)
                                MarkerLayer(
                                  markers: [
                                    Marker(
                                      point: currentLatLng,
                                      width: 32,
                                      height: 32,
                                      child: AnimatedContainer(
                                        duration: const Duration(milliseconds: 400),
                                        curve: Curves.easeInOut,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          boxShadow: [
                                            BoxShadow(
                                              color: _dotStale ? Colors.orange : Colors.blue.withAlpha((0.4 * 255).toInt()),
                                              blurRadius: 16,
                                              spreadRadius: 4,
                                            ),
                                          ],
                                        ),
                                        child: Center(
                                          child: AnimatedContainer(
                                            duration: const Duration(milliseconds: 400),
                                            width: 18 + speed * 0.2,
                                            height: 18 + speed * 0.2,
                                            decoration: BoxDecoration(
                                              color: _dotStale ? Colors.orange : Colors.blue,
                                              shape: BoxShape.circle,
                                              border: Border.all(color: Colors.white, width: 3),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _StatCard(label: 'Duration', value: _formatDuration(duration), unit: '', color: darkCyan),
                _StatCard(label: 'Distance', value: distance.toStringAsFixed(2), unit: distanceUnit, color: darkCyan),
                _StatCard(label: 'Max', value: _maxSpeed.toStringAsFixed(1), unit: speedUnit, color: darkCyan),
                _StatCard(label: 'Avg', value: _avgSpeed.toStringAsFixed(1), unit: speedUnit, color: darkCyan),
              ],
            ),
            const SizedBox(height: 24),
            Center(
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _isRiding ? Colors.redAccent : darkCyan,
                  padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
                ),
                onPressed: _toggleRide,
                child: Text(_isRiding ? 'Stop Ride' : 'Start Ride', style: const TextStyle(fontSize: 24, color: Colors.white)),
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration d) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final h = twoDigits(d.inHours);
    final m = twoDigits(d.inMinutes.remainder(60));
    final s = twoDigits(d.inSeconds.remainder(60));
    return "$h:$m:$s";
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final String unit;
  final Color color;
  const _StatCard({required this.label, required this.value, required this.unit, required this.color});
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(label, style: TextStyle(color: color, fontSize: 16)),
        Text(value, style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold)),
        if (unit.isNotEmpty)
          Text(unit, style: TextStyle(color: color, fontSize: 16)),
      ],
    );
  }
}