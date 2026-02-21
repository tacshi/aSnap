import 'package:flutter/foundation.dart';

enum CaptureStatus { idle, capturing, selecting, captured }

class AppState extends ChangeNotifier {
  Uint8List? _screenshotBytes;
  Uint8List? get screenshotBytes => _screenshotBytes;

  Uint8List? _fullScreenBytes;
  Uint8List? get fullScreenBytes => _fullScreenBytes;

  CaptureStatus _status = CaptureStatus.idle;
  CaptureStatus get status => _status;

  void setCapturing() {
    _status = CaptureStatus.capturing;
    notifyListeners();
  }

  void setSelecting(Uint8List fullScreenBytes) {
    _fullScreenBytes = fullScreenBytes;
    _status = CaptureStatus.selecting;
    notifyListeners();
  }

  void setCapturedImage(Uint8List bytes) {
    _screenshotBytes = bytes;
    _fullScreenBytes = null;
    _status = CaptureStatus.captured;
    notifyListeners();
  }

  void clear() {
    _screenshotBytes = null;
    _fullScreenBytes = null;
    _status = CaptureStatus.idle;
    notifyListeners();
  }
}
