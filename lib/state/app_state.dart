import 'dart:ui';

import 'package:flutter/foundation.dart';

enum CaptureStatus {
  idle,
  capturing,
  selecting,
  scrollSelecting,
  scrollCapturing,
  captured,
}

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

  /// Whether the current captured image is from a scroll capture (for scrollable preview).
  bool _isScrollCapture = false;
  bool get isScrollCapture => _isScrollCapture;

  /// CG bounds of the scroll target window (for badge placement).
  Rect? _scrollTargetBounds;
  Rect? get scrollTargetBounds => _scrollTargetBounds;

  /// Live frame count during scroll capture (for badge).
  int _scrollFrameCount = 0;
  int get scrollFrameCount => _scrollFrameCount;

  /// Growing composite image for live scroll preview.
  /// Owned by ScrollCaptureService — do NOT dispose here.
  Image? _scrollPreviewImage;
  Image? get scrollPreviewImage => _scrollPreviewImage;

  CaptureStatus _status = CaptureStatus.idle;
  CaptureStatus get status => _status;

  void setCapturing() {
    _status = CaptureStatus.capturing;
    notifyListeners();
  }

  void setScrollSelecting({
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
    _status = CaptureStatus.scrollSelecting;
    notifyListeners();
  }

  void setScrollCapturing({required Rect captureRegion}) {
    _scrollTargetBounds = captureRegion;
    _scrollFrameCount = 0;
    _status = CaptureStatus.scrollCapturing;
    notifyListeners();
  }

  void updateScrollFrameCount(int count) {
    _scrollFrameCount = count;
    notifyListeners();
  }

  /// Update the live scroll preview image (called by ScrollCaptureService).
  /// The image is owned by the service — we just hold a reference.
  /// Does NOT call notifyListeners() — the caller is responsible for
  /// triggering a rebuild (via updateScrollFrameCount) after setting this.
  void updateScrollPreview(Image newImage) {
    _scrollPreviewImage = newImage;
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
    _isScrollCapture = false;
    _status = CaptureStatus.captured;
    notifyListeners();
  }

  void setCapturedScrollImage(Image image) {
    _capturedImage?.dispose();
    _capturedImage = image;
    _decodedFullScreen?.dispose();
    _decodedFullScreen = null;
    _windowRects = null;
    _scrollTargetBounds = null;
    _scrollPreviewImage = null; // Service owns it; just clear reference
    _isScrollCapture = true;
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

  /// Remove and return the captured image without disposing it.
  /// Caller takes ownership and is responsible for disposal.
  Image? detachCapturedImage() {
    final image = _capturedImage;
    _capturedImage = null;
    return image;
  }

  /// Remove and return the full-screen decoded image without disposing it.
  /// Caller takes ownership and is responsible for disposal.
  /// Used by overlay copy/save to detach before clear() disposes it.
  Image? detachDecodedFullScreen() {
    final image = _decodedFullScreen;
    _decodedFullScreen = null;
    return image;
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
    _isScrollCapture = false;
    _scrollTargetBounds = null;
    _scrollFrameCount = 0;
    _scrollPreviewImage = null; // Service owns it; just clear reference
    _status = CaptureStatus.idle;
    notifyListeners();
  }
}
