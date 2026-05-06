/*
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
      home: FaceBlinkScreen(),
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

  // Detection output
  int _faceCount = 0;
  int _blinkCount = 0;
  bool _eyesClosed = false;
  int _framesClosed = 0;

  // EAR smoothing: keep last 3 values to reduce noise
  final List<double> _earSmooth = [];
  double? _displayEAR;

  // Overlay drawing data
  List<Point>? _leftContour;
  List<Point>? _rightContour;
  BoundingBox? _faceBox;
  Size? _imageSize;

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

    // frontCamera model for selfie; full mode provides iris + eye contour
    _detector = await FaceDetector.create(
      model: FaceDetectionModel.frontCamera,
    );

    setState(() {});
    _startLoop();
  }

  // takePicture() on Windows desktop gives a proper JPEG that the TFLite
  // pipeline can decode. startImageStream gives raw YUV/BGRA bytes which
  // detectFaces() cannot parse, leaving irisPoints empty → eyes == null.
  void _startLoop() {
    _timer = Timer.periodic(const Duration(milliseconds: 130), (_) async {
      if (_busy || !mounted) return;
      _busy = true;

      try {
        final file = await _camera.takePicture();
        final bytes = await file.readAsBytes();

        // FaceDetectionMode.full runs the iris pipeline and populates
        // face.eyes with left/right Eye objects each having a .contour
        // (15-point eyelid outline) and .mesh (71 points).
        final faces = await _detector!.detectFaces(
          bytes,
          mode: FaceDetectionMode.full,
        );

        if (faces.isNotEmpty) {
          final face = faces.first;
          final eyes = face.eyes;

          if (eyes?.leftEye != null && eyes?.rightEye != null) {
            // eye.contour = first 15 points of the 71-point mesh.
            // These are the EYELID points only — not eyebrows or halos.
            // The remaining 56 points are eyebrow / tracking halo and
            // must NOT be used for EAR (their bbox barely changes on blink).
            final lContour = eyes!.leftEye!.contour;
            final rContour = eyes.rightEye!.contour;

            final leftEAR = _ear(lContour);
            final rightEAR = _ear(rContour);
            final avg = (leftEAR + rightEAR) / 2;

            // Rolling average to smooth per-frame noise
            _earSmooth.add(avg);
            if (_earSmooth.length > 3) _earSmooth.removeAt(0);
            final smoothed =
                _earSmooth.reduce((a, b) => a + b) / _earSmooth.length;

            _detectBlink(smoothed);
            setState(() {
              _faceCount = faces.length;
              _leftContour = lContour;
              _rightContour = rContour;
              _faceBox = face.boundingBox;
              _imageSize = face.originalSize;
              _displayEAR = smoothed;
            });

            debugPrint(
              'EAR L=${leftEAR.toStringAsFixed(3)} '
                  'R=${rightEAR.toStringAsFixed(3)} '
                  'avg=${smoothed.toStringAsFixed(3)} '
                  'closed=$_eyesClosed',
            );
          } else {
            // Face found but iris pipeline produced no eye data.
            // Log once to help diagnose if this persists.
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

  // EAR using the 15-point eyelid contour from the package.
  //
  // Layout (from eyeLandmarkConnections in the package source):
  //   upper lid: 0→1→2→3→4→5→6→7→8   (index 4 = top center)
  //   lower lid: 9→10→11→12→13→14     (index 12 = bottom center)
  //   corners:   [0,9] and [8,14]
  //
  // So:
  //   horizontal = dist(contour[0], contour[8])  — left to right corner
  //   vertical   = dist(contour[4], contour[12]) — upper-lid peak to lower-lid trough
  //
  // Eyes open  → vertical is large → EAR ≈ 0.25–0.40
  // Eyes closed → vertical is tiny  → EAR ≈ 0.02–0.12
  double _ear(List<Point> c) {
    if (c.length < 15) return 0;

    final horiz = _d(c[0], c[8]);
    if (horiz == 0) return 0;
    final vert = _d(c[4], c[12]);
    return vert / horiz;
  }

  double _d(Point a, Point b) =>
      sqrt(pow(a.x - b.x, 2) + pow(a.y - b.y, 2));

  // Threshold chosen from the MediaPipe iris model behavior:
  // open ≈ 0.25–0.40, closed ≈ 0.02–0.15 → threshold at 0.20 sits cleanly
  // between them. A minimum of 1 frame below threshold and maximum of 10
  // frames prevents both false-positives (noise) and false-negatives (long
  // closures being missed).
  static const double _earThreshold = 0.20;

  void _detectBlink(double ear) {
    if (ear < _earThreshold) {
      _framesClosed++;
      _eyesClosed = true;
    } else {
      if (_eyesClosed && _framesClosed >= 1 && _framesClosed <= 10) {
        setState(() => _blinkCount++);
        debugPrint('BLINK #$_blinkCount (${_framesClosed} frames)');
      }
      _eyesClosed = false;
      _framesClosed = 0;
    }
  }

  void _resetFace() {
    setState(() {
      _faceCount = 0;
      _leftContour = null;
      _rightContour = null;
      _faceBox = null;
      _displayEAR = null;
    });
    _eyesClosed = false;
    _framesClosed = 0;
    _earSmooth.clear();
  }

  void _reset() {
    setState(() {
      _blinkCount = 0;
      _displayEAR = null;
    });
    _eyesClosed = false;
    _framesClosed = 0;
    _earSmooth.clear();
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
          // Camera + overlay
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

                  // Eyes-closed banner
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
                ],
              );
            }),
          ),

          // Info panel
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

                  const SizedBox(height: 16),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 80),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 8),
                    decoration: BoxDecoration(
                      color: _eyesClosed ? Colors.red : Colors.green,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _eyesClosed ? 'EYES CLOSED' : 'EYES OPEN',
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 15),
                    ),
                  ),

                  const SizedBox(height: 20),
                  if (_displayEAR != null) ...[
                    Text(
                      'EAR: ${_displayEAR!.toStringAsFixed(3)}',
                      style:
                      const TextStyle(color: Colors.white60, fontSize: 13),
                    ),
                    const Text(
                      'Threshold: 0.200',
                      style:
                      TextStyle(color: Colors.white38, fontSize: 11),
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

    // Face bounding box
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

    // Draw upper lid: points 0→8
    final upper = Path();
    upper.moveTo(o(contour[0]).dx, o(contour[0]).dy);
    for (int i = 1; i <= 8; i++) {
      upper.lineTo(o(contour[i]).dx, o(contour[i]).dy);
    }
    canvas.drawPath(upper, stroke);

    // Draw lower lid: points 9→14
    final lower = Path();
    lower.moveTo(o(contour[9]).dx, o(contour[9]).dy);
    for (int i = 10; i <= 14; i++) {
      lower.lineTo(o(contour[i]).dx, o(contour[i]).dy);
    }
    canvas.drawPath(lower, stroke);

    // Corner connectors: [0,9] and [8,14]
    canvas.drawLine(o(contour[0]), o(contour[9]), stroke);
    canvas.drawLine(o(contour[8]), o(contour[14]), stroke);

    // Key EAR points highlighted
    canvas.drawCircle(o(contour[0]), 3, dot);   // left corner
    canvas.drawCircle(o(contour[8]), 3, dot);   // right corner
    canvas.drawCircle(o(contour[4]), 4, dot);   // top center
    canvas.drawCircle(o(contour[12]), 4, dot);  // bottom center
  }

  @override
  bool shouldRepaint(covariant EyelidPainter old) =>
      old.closed != closed ||
          old.left != left ||
          old.right != right ||
          old.imageSize != imageSize;
}
*/
