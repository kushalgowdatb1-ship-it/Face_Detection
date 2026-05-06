import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:face_detection_tflite/face_detection_tflite.dart';

late List<CameraDescription> cameras;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  cameras = await availableCameras();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: OnboardingScreen(),
    );
  }
}

class OnboardingScreen extends StatelessWidget {
  const OnboardingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.remove_red_eye_outlined, size: 80, color: Colors.blueAccent),
            const SizedBox(height: 24),
            const Text(
              'Eye Blink Detector',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            const Text(
              'Detect and count your eye blinks in real time.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, color: Colors.grey),
            ),
            const SizedBox(height: 48),
            ElevatedButton.icon(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const FaceBlinkScreen()),
              ),
              icon: const Icon(Icons.camera_alt),
              label: const Text('Start Detection'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                textStyle: const TextStyle(fontSize: 18),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class FaceBlinkScreen extends StatefulWidget {
  const FaceBlinkScreen({super.key});

  @override
  State<FaceBlinkScreen> createState() => _FaceBlinkScreenState();
}

class _FaceBlinkScreenState extends State<FaceBlinkScreen> {
  late CameraController _camera;
  FaceDetector? _detector;
  Timer? _timer;
  bool _busy = false;

  int _faceCount = 0;
  int _blinkCount = 0;
  double? _displayEAR;

  List<Point>? _leftContour;
  List<Point>? _rightContour;
  BoundingBox? _faceBox;
  Size? _imageSize;


  static const double _earThreshold = 0.25;
  static const int _consecFrames = 1;
  static const double _blinkDebounce = 0.25;
  static const double _blinkHoldDuration = 0.4;

  int _blinkCounter = 0;
  bool _eyesClosed = false;
  bool _blinkStatus = false; // holds True for 0.3 s after blink event
  double _lastBlinkTime = 0.0;
  double _blinkHoldUntil = 0.0;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _camera = CameraController(
      cameras.first,
      ResolutionPreset.medium,
      enableAudio: false,
    );
    await _camera.initialize();

    _detector = await FaceDetector.create(
      model: FaceDetectionModel.frontCamera,
    );

    setState(() {});
    _startLoop();
  }

  void _startLoop() {
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) async {
      if (_busy || !mounted) return;
      _busy = true;

      try {
        final file = await _camera.takePicture();
        final bytes = await file.readAsBytes();

        final faces = await _detector!.detectFaces(
          bytes,
          mode: FaceDetectionMode.full,
        );

        if (faces.isNotEmpty) {
          final face = faces.first;
          final eyes = face.eyes;

          if (eyes?.leftEye != null && eyes?.rightEye != null) {
            final lContour = eyes!.leftEye!.contour;
            final rContour = eyes.rightEye!.contour;

            final leftEAR = _ear(lContour);
            final rightEAR = _ear(rContour);
            final avg = (leftEAR + rightEAR) / 2;

            _detectBlink(avg);

            setState(() {
              _faceCount = faces.length;
              _leftContour = lContour;
              _rightContour = rContour;
              _faceBox = face.boundingBox;
              _imageSize = face.originalSize;
              _displayEAR = avg;
            });

            debugPrint(
              'EAR L=${leftEAR.toStringAsFixed(3)} '
              'R=${rightEAR.toStringAsFixed(3)} '
              'avg=${avg.toStringAsFixed(3)} '
              'thresh=$_earThreshold '
              'closed=$_eyesClosed blink=$_blinkStatus',
            );
          } else {
            debugPrint(
              'face.eyes=${eyes == null ? "null" : "present"} '
              'left=${eyes?.leftEye == null ? "null" : "ok"} '
              'right=${eyes?.rightEye == null ? "null" : "ok"} '
              'irisPoints=${face.irisPoints.length}',
            );
            setState(() {
              _faceCount = faces.length;
              _leftContour = null;
              _rightContour = null;
              _displayEAR = null;
            });
          }
        } else {
          _resetFace();
        }
      } catch (e) {
        debugPrint('Detection error: $e');
      }

      _busy = false;
    });
  }

  // Classic 6-point EAR: (A + B) / (2 * C)
  // A = left vertical  (c[3] ↔ c[11])
  // B = right vertical (c[5] ↔ c[13])
  // C = horizontal     (c[0] ↔ c[8])
  double _ear(List<Point> c) {
    if (c.length < 15) return 0;
    final horiz = _d(c[0], c[8]);
    if (horiz == 0) return 0;
    final a = _d(c[3], c[11]);
    final b = _d(c[5], c[13]);
    return (a + b) / (2.0 * horiz);
  }

  double _d(Point a, Point b) =>
      sqrt(pow(a.x - b.x, 2) + pow(a.y - b.y, 2));

  // Mirrors the Python state machine exactly.
  void _detectBlink(double ear) {
    final now = DateTime.now().millisecondsSinceEpoch / 1000.0;

    if (ear < _earThreshold) {
      _blinkCounter++;
      if (_blinkCounter >= _consecFrames) {
        _eyesClosed = true;
      }
    } else {
      if (_eyesClosed) {
        if (now - _lastBlinkTime > _blinkDebounce) {
          _lastBlinkTime = now;
          _blinkHoldUntil = now + _blinkHoldDuration;
          setState(() => _blinkCount++);
          debugPrint('BLINK #$_blinkCount');
        }
      }
      _blinkCounter = 0;
      _eyesClosed = false;
    }

    final newStatus = now < _blinkHoldUntil;
    if (newStatus != _blinkStatus) {
      setState(() => _blinkStatus = newStatus);
    }
  }

  void _resetFace() {
    setState(() {
      _faceCount = 0;
      _leftContour = null;
      _rightContour = null;
      _faceBox = null;
      _displayEAR = null;
      _blinkStatus = false;
      _eyesClosed = false;
    });
    _blinkCounter = 0;
  }

  void _reset() {
    setState(() {
      _blinkCount = 0;
      _displayEAR = null;
      _blinkStatus = false;
      _eyesClosed = false;
    });
    _blinkCounter = 0;
    _lastBlinkTime = 0;
    _blinkHoldUntil = 0;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _camera.dispose();
    _detector?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_camera.value.isInitialized) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      body: Row(
        children: [
          Expanded(
            flex: 2,
            child: LayoutBuilder(builder: (ctx, constraints) {
              return Stack(
                children: [
                  CameraPreview(_camera),

                  if (_imageSize != null)
                    CustomPaint(
                      size: Size(constraints.maxWidth, constraints.maxHeight),
                      painter: EyelidPainter(
                        left: _leftContour,
                        right: _rightContour,
                        faceBox: _faceBox,
                        imageSize: _imageSize!,
                        closed: _eyesClosed,
                      ),
                    ),

                  if (_eyesClosed)
                    Positioned(
                      top: 16,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 24, vertical: 10),
                          decoration: BoxDecoration(
                            color: Colors.red.withOpacity(0.85),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Text(
                            'EYES CLOSED',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 20,
                                fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    ),

                  if (_blinkStatus )
                    Positioned(
                      top: 16,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 24, vertical: 10),
                          decoration: BoxDecoration(
                            color: Colors.amber.withOpacity(0.9),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Text(
                            'BLINK!',
                            style: TextStyle(
                                color: Colors.black,
                                fontSize: 20,
                                fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            }),
          ),

          Expanded(
            child: Container(
              color: _faceCount > 0
                  ? const Color(0xFF1B5E20)
                  : const Color(0xFFB71C1C),
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _faceCount > 0
                        ? Icons.face
                        : Icons.face_retouching_off,
                    color: Colors.white,
                    size: 52,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _faceCount > 0 ? 'Face Detected' : 'No Face',
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                  ),

                  const SizedBox(height: 28),
                  const Text('Blink Count',
                      style: TextStyle(color: Colors.white60, fontSize: 13)),
                  Text(
                    '$_blinkCount',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 60,
                        fontWeight: FontWeight.bold),
                  ),

                  const SizedBox(height: 20),
                  if (_displayEAR != null) ...[
                    Text(
                      'EAR: ${_displayEAR!.toStringAsFixed(3)}',
                      style: const TextStyle(
                          color: Colors.white60, fontSize: 13),
                    ),
                    const Text(
                      'Threshold: 0.230',
                      style: TextStyle(color: Colors.white38, fontSize: 11),
                    ),
                    const SizedBox(height: 8),
                    _EarBar(
                      ear: _displayEAR!,
                      threshold: _earThreshold,
                    ),
                  ] else if (_faceCount > 0) ...[
                    const Text(
                      'Eye data loading…',
                      style: TextStyle(color: Colors.white60, fontSize: 13),
                    ),
                  ],

                  const SizedBox(height: 24),
                  TextButton.icon(
                    onPressed: _reset,
                    icon: const Icon(Icons.refresh, color: Colors.white70),
                    label: const Text('Reset',
                        style: TextStyle(color: Colors.white70)),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EarBar extends StatelessWidget {
  final double ear;
  final double threshold;

  const _EarBar({required this.ear, required this.threshold});

  @override
  Widget build(BuildContext context) {
    final scale = threshold * 2.5;
    final ratio = (ear / scale).clamp(0.0, 1.0);
    final threshRatio = (threshold / scale).clamp(0.0, 1.0);
    return SizedBox(
      width: double.infinity,
      height: 12,
      child: CustomPaint(
        painter: _EarBarPainter(ratio: ratio, threshRatio: threshRatio),
      ),
    );
  }
}

class _EarBarPainter extends CustomPainter {
  final double ratio;
  final double threshRatio;

  const _EarBarPainter({required this.ratio, required this.threshRatio});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(0, 0, size.width, size.height),
          const Radius.circular(6)),
      Paint()..color = Colors.white.withOpacity(0.2),
    );

    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(0, 0, size.width * ratio, size.height),
          const Radius.circular(6)),
      Paint()
        ..color = (ratio < threshRatio ? Colors.red : Colors.green)
            .withOpacity(0.85),
    );

    canvas.drawLine(
      Offset(size.width * threshRatio, 0),
      Offset(size.width * threshRatio, size.height),
      Paint()
        ..color = Colors.white.withOpacity(0.9)
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant _EarBarPainter old) =>
      old.ratio != ratio || old.threshRatio != threshRatio;
}

class EyelidPainter extends CustomPainter {
  final List<Point>? left;
  final List<Point>? right;
  final BoundingBox? faceBox;
  final Size imageSize;
  final bool closed;

  const EyelidPainter({
    this.left,
    this.right,
    this.faceBox,
    required this.imageSize,
    required this.closed,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (imageSize.width == 0 || imageSize.height == 0) return;

    final sx = size.width / imageSize.width;
    final sy = size.height / imageSize.height;

    Offset o(Point p) => Offset(p.x * sx, p.y * sy);

    if (faceBox != null) {
      canvas.drawRect(
        Rect.fromPoints(o(faceBox!.topLeft), o(faceBox!.bottomRight)),
        Paint()
          ..color = Colors.blue.withOpacity(0.7)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }

    final color = closed ? Colors.red : Colors.cyanAccent;
    _drawEyelid(canvas, left, color, o);
    _drawEyelid(canvas, right, color, o);
  }

  void _drawEyelid(
    Canvas canvas,
    List<Point>? contour,
    Color color,
    Offset Function(Point) o,
  ) {
    if (contour == null || contour.length < 15) return;

    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8;
    final dot = Paint()..color = color;

    final upper = Path();
    upper.moveTo(o(contour[0]).dx, o(contour[0]).dy);
    for (int i = 1; i <= 8; i++) {
      upper.lineTo(o(contour[i]).dx, o(contour[i]).dy);
    }
    canvas.drawPath(upper, stroke);

    final lower = Path();
    lower.moveTo(o(contour[9]).dx, o(contour[9]).dy);
    for (int i = 10; i <= 14; i++) {
      lower.lineTo(o(contour[i]).dx, o(contour[i]).dy);
    }
    canvas.drawPath(lower, stroke);

    canvas.drawLine(o(contour[0]), o(contour[9]), stroke);
    canvas.drawLine(o(contour[8]), o(contour[14]), stroke);

    // Corner points (horizontal)
    canvas.drawCircle(o(contour[0]), 3, dot);
    canvas.drawCircle(o(contour[8]), 3, dot);
    // EAR measurement points: A = c[3]↔c[11], B = c[5]↔c[13]
    canvas.drawCircle(o(contour[3]), 3, dot);
    canvas.drawCircle(o(contour[11]), 3, dot);
    canvas.drawCircle(o(contour[5]), 3, dot);
    canvas.drawCircle(o(contour[13]), 3, dot);
  }

  @override
  bool shouldRepaint(covariant EyelidPainter old) =>
      old.closed != closed ||
      old.left != left ||
      old.right != right ||
      old.imageSize != imageSize;
}
