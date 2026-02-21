import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:screen_capturer/screen_capturer.dart';

class CaptureService {
  Future<Uint8List?> captureFullScreen() async {
    if (!await _ensurePermission()) return null;

    final imagePath = await _tempImagePath();
    final capturedData = await screenCapturer.capture(
      mode: CaptureMode.screen,
      imagePath: imagePath,
      copyToClipboard: false,
      silent: true,
    );
    return _readAndCleanup(capturedData, imagePath);
  }

  Future<Uint8List?> captureRegion() async {
    if (!await _ensurePermission()) return null;

    final imagePath = await _tempImagePath();
    final capturedData = await screenCapturer.capture(
      mode: CaptureMode.region,
      imagePath: imagePath,
      copyToClipboard: false,
      silent: true,
    );
    return _readAndCleanup(capturedData, imagePath);
  }

  Future<bool> checkPermission() async {
    if (Platform.isMacOS) {
      return await screenCapturer.isAccessAllowed();
    }
    return true;
  }

  Future<void> requestPermission() async {
    if (Platform.isMacOS) {
      try {
        await screenCapturer.requestAccess();
      } catch (e) {
        debugPrint('[aSnap] requestAccess failed: $e');
      }
      // Also open System Settings directly as a fallback
      await _openScreenRecordingSettings();
    }
  }

  /// Check permission and prompt if not granted. Returns true if allowed.
  Future<bool> _ensurePermission() async {
    if (!Platform.isMacOS) return true;

    final allowed = await screenCapturer.isAccessAllowed();
    if (!allowed) {
      debugPrint(
        '[aSnap] Screen recording permission not granted, opening System Settings...',
      );
      await _openScreenRecordingSettings();
      return false;
    }
    return true;
  }

  /// Open macOS System Settings > Privacy & Security > Screen Recording
  Future<void> _openScreenRecordingSettings() async {
    await Process.run('open', [
      'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture',
    ]);
  }

  Future<String> _tempImagePath() async {
    final dir = await getTemporaryDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    return '${dir.path}/asnap_capture_$timestamp.png';
  }

  Future<Uint8List?> _readAndCleanup(
    CapturedData? capturedData,
    String imagePath,
  ) async {
    if (capturedData == null) return null;

    final file = File(imagePath);
    if (await file.exists()) {
      final bytes = await file.readAsBytes();
      try {
        await file.delete();
      } catch (e) {
        debugPrint(
          '[aSnap] Failed to delete temp capture file at $imagePath: $e',
        );
      }
      return bytes;
    }
    return null;
  }
}
