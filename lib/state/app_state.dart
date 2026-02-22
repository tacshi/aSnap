import 'dart:ui';

import 'package:flutter/foundation.dart';

enum CaptureStatus { idle, capturing, selecting, captured }

class AppState extends ChangeNotifier {
  /// Pre-decoded full-screen image for instant display in the overlay.
  /// Owned by AppState — disposed when replaced or cleared.
  Image? _decodedFullScreen;
  Image? get decodedFullScreen => _decodedFullScreen;

  /// The final captured image (full-screen or cropped region) for preview.
  /// Owned by AppState — disposed when replaced or cleared.
  Image? _capturedImage;
  Image? get capturedImage => _capturedImage;

  List<Rect>? _windowRects;
  List<Rect>? get windowRects => _windowRects;

  /// Logical size of the display that was captured (for correct scaling).
  Size? _screenSize;
  Size? get screenSize => _screenSize;

  /// Top-left origin (CG-style coordinates) of the captured display.
  Offset? _screenOrigin;
  Offset? get screenOrigin => _screenOrigin;

  CaptureStatus _status = CaptureStatus.idle;
  CaptureStatus get status => _status;

  void setCapturing() {
    _status = CaptureStatus.capturing;
    notifyListeners();
  }

  void setSelecting({
    required Image decodedImage,
    List<Rect>? windowRects,
    Size? screenSize,
    Offset? screenOrigin,
  }) {
    _decodedFullScreen?.dispose();
    _decodedFullScreen = decodedImage;
    _windowRects = windowRects;
    _screenSize = screenSize;
    _screenOrigin = screenOrigin;
    _status = CaptureStatus.selecting;
    notifyListeners();
  }

  /// Update only the window rects (used when rects arrive after the overlay
  /// is already showing, e.g. during a display change).
  void updateWindowRects(List<Rect> rects) {
    _windowRects = rects;
    notifyListeners();
  }

  void setCapturedImage(Image image) {
    _capturedImage?.dispose();
    _capturedImage = image;
    _decodedFullScreen?.dispose();
    _decodedFullScreen = null;
    _windowRects = null;
    _screenSize = null;
    _screenOrigin = null;
    _status = CaptureStatus.captured;
    notifyListeners();
  }

  /// Encode the captured image to PNG bytes on demand (for clipboard/file save).
  Future<Uint8List?> capturedImageAsPng() async {
    final image = _capturedImage;
    if (image == null) return null;
    final byteData = await image.toByteData(format: ImageByteFormat.png);
    return byteData?.buffer.asUint8List();
  }

  /// Trigger a rebuild without changing any state.
  /// Used when the native window is shown/focused after initial state updates.
  void nudge() {
    notifyListeners();
  }

  void clear() {
    _capturedImage?.dispose();
    _capturedImage = null;
    _decodedFullScreen?.dispose();
    _decodedFullScreen = null;
    _windowRects = null;
    _screenSize = null;
    _screenOrigin = null;
    _status = CaptureStatus.idle;
    notifyListeners();
  }
}
