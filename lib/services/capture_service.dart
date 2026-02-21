import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:screen_capturer/screen_capturer.dart';

class CaptureService {
  Future<Uint8List?> captureFullScreen() async {
    if (!await _ensurePermission()) return null;

    final imagePath = await _tempImagePath();
    // Call screencapture directly without -C to exclude the mouse cursor
    final result = await Process.run('/usr/sbin/screencapture', [
      '-x',
      imagePath,
    ]);
    if (result.exitCode != 0) return null;
    return _readFile(imagePath);
  }

  /// Crop a region from a full-screen PNG image.
  /// [physicalRect] is in physical pixel coordinates.
  Future<Uint8List?> cropImage(Uint8List pngBytes, ui.Rect physicalRect) async {
    final codec = await ui.instantiateImageCodec(pngBytes);
    final frame = await codec.getNextFrame();
    final image = frame.image;

    final clampedLeft = physicalRect.left.clamp(0.0, image.width.toDouble());
    final clampedTop = physicalRect.top.clamp(0.0, image.height.toDouble());
    final srcRect = ui.Rect.fromLTWH(
      clampedLeft,
      clampedTop,
      physicalRect.width.clamp(0, image.width - clampedLeft),
      physicalRect.height.clamp(0, image.height - clampedTop),
    );

    if (srcRect.width <= 0 || srcRect.height <= 0) {
      image.dispose();
      codec.dispose();
      return null;
    }

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final dstRect = ui.Rect.fromLTWH(0, 0, srcRect.width, srcRect.height);
    canvas.drawImageRect(image, srcRect, dstRect, ui.Paint());
    final picture = recorder.endRecording();

    final cropped = await picture.toImage(
      srcRect.width.round(),
      srcRect.height.round(),
    );
    final byteData = await cropped.toByteData(format: ui.ImageByteFormat.png);

    image.dispose();
    codec.dispose();
    picture.dispose();
    cropped.dispose();

    return byteData?.buffer.asUint8List();
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

  Future<Uint8List?> _readFile(String imagePath) async {
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
