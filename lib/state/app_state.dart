import 'package:flutter/foundation.dart';

enum CaptureStatus { idle, capturing, captured }

class AppState extends ChangeNotifier {
  Uint8List? _screenshotBytes;
  Uint8List? get screenshotBytes => _screenshotBytes;

  CaptureStatus _status = CaptureStatus.idle;
  CaptureStatus get status => _status;

  void setCapturing() {
    _status = CaptureStatus.capturing;
    notifyListeners();
  }

  void setCapturedImage(Uint8List bytes) {
    _screenshotBytes = bytes;
    _status = CaptureStatus.captured;
    notifyListeners();
  }

  void clear() {
    _screenshotBytes = null;
    _status = CaptureStatus.idle;
    notifyListeners();
  }
}
