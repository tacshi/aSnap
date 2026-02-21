import 'dart:ui';

import 'package:flutter/foundation.dart';

enum CaptureStatus { idle, capturing, selecting, captured }

class AppState extends ChangeNotifier {
  Uint8List? _screenshotBytes;
  Uint8List? get screenshotBytes => _screenshotBytes;

  Uint8List? _fullScreenBytes;
  Uint8List? get fullScreenBytes => _fullScreenBytes;

  /// Pre-decoded full-screen image for instant display in the overlay.
  /// Owned by AppState — disposed when replaced or cleared.
  Image? _decodedFullScreen;
  Image? get decodedFullScreen => _decodedFullScreen;

  List<Rect>? _windowRects;
  List<Rect>? get windowRects => _windowRects;

  /// Logical size of the display that was captured (for correct scaling).
  Size? _screenSize;
  Size? get screenSize => _screenSize;

  CaptureStatus _status = CaptureStatus.idle;
  CaptureStatus get status => _status;

  void setCapturing() {
    _status = CaptureStatus.capturing;
    notifyListeners();
  }

  void setSelecting(
    Uint8List fullScreenBytes, {
    required Image decodedImage,
    List<Rect>? windowRects,
    Size? screenSize,
  }) {
    _decodedFullScreen?.dispose();
    _decodedFullScreen = decodedImage;
    _fullScreenBytes = fullScreenBytes;
    _windowRects = windowRects;
    _screenSize = screenSize;
    _status = CaptureStatus.selecting;
    notifyListeners();
  }

  /// Update only the window rects (used when rects arrive after the overlay
  /// is already showing, e.g. during a display change).
  void updateWindowRects(List<Rect> rects) {
    _windowRects = rects;
    notifyListeners();
  }

  void setCapturedImage(Uint8List bytes) {
    _screenshotBytes = bytes;
    _fullScreenBytes = null;
    _decodedFullScreen?.dispose();
    _decodedFullScreen = null;
    _windowRects = null;
    _screenSize = null;
    _status = CaptureStatus.captured;
    notifyListeners();
  }

  void clear() {
    _screenshotBytes = null;
    _fullScreenBytes = null;
    _decodedFullScreen?.dispose();
    _decodedFullScreen = null;
    _windowRects = null;
    _screenSize = null;
    _status = CaptureStatus.idle;
    notifyListeners();
  }
}
