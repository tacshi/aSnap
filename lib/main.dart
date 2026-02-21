import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'services/capture_service.dart';
import 'services/clipboard_service.dart';
import 'services/file_service.dart';
import 'services/hotkey_service.dart';
import 'services/tray_service.dart';
import 'services/window_service.dart';
import 'state/app_state.dart';

late final AppState _appState;
late final CaptureService _captureService;
late final ClipboardService _clipboardService;
late final FileService _fileService;
late final HotkeyService _hotkeyService;
late final TrayService _trayService;
late final WindowService _windowService;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  _appState = AppState();
  _captureService = CaptureService();
  _clipboardService = ClipboardService();
  _fileService = FileService();
  _hotkeyService = HotkeyService();
  _trayService = TrayService();
  _windowService = WindowService();

  await _windowService.ensureInitialized();

  runApp(
    ASnapApp(
      appState: _appState,
      onCopy: _handleCopy,
      onSave: _handleSave,
      onDiscard: _handleDiscard,
      onRegionSelected: _handleRegionSelected,
      onRegionCancel: _handleRegionCancel,
    ),
  );

  await _initAfterRunApp();
}

Future<void> _initAfterRunApp() async {
  await _windowService.hideOnReady();

  if (Platform.isMacOS) {
    final hasPermission = await _captureService.checkPermission();
    if (!hasPermission) {
      await _captureService.requestPermission();
    }
  }

  await _trayService.init();
  _trayService.onCaptureFullScreen = _handleFullScreenCapture;
  _trayService.onCaptureRegion = _handleRegionCapture;
  _trayService.onQuit = _handleQuit;

  await _hotkeyService.register(
    onFullScreen: _handleFullScreenCapture,
    onRegion: _handleRegionCapture,
  );
}

/// Decode image dimensions from PNG bytes.
Future<Size> _getImageSize(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final size = Size(
    frame.image.width.toDouble(),
    frame.image.height.toDouble(),
  );
  frame.image.dispose();
  codec.dispose();
  return size;
}

Future<void> _showPreviewWithImage(Uint8List bytes) async {
  _appState.setCapturedImage(bytes);
  final imgSize = await _getImageSize(bytes);
  await _windowService.showPreview(
    imageWidth: imgSize.width.toInt(),
    imageHeight: imgSize.height.toInt(),
  );
}

Future<void> _handleFullScreenCapture() async {
  if (_appState.status == CaptureStatus.capturing) return;
  _appState.setCapturing();
  await _windowService.hidePreview();

  final bytes = await _captureService.captureFullScreen();
  if (bytes != null) {
    await _showPreviewWithImage(bytes);
  } else {
    _appState.clear();
  }
}

Future<void> _handleRegionCapture() async {
  if (_appState.status == CaptureStatus.capturing ||
      _appState.status == CaptureStatus.selecting) {
    return;
  }
  _appState.setCapturing();
  await _windowService.hidePreview();

  // Capture full screen silently, then show transparent overlay immediately
  final bytes = await _captureService.captureFullScreen();
  if (bytes != null) {
    _appState.setSelecting(bytes);
    await _windowService.showFullScreenOverlay();
  } else {
    _appState.clear();
  }
}

Future<void> _handleRegionSelected(Rect logicalRect) async {
  final fullScreenBytes = _appState.fullScreenBytes;
  if (fullScreenBytes == null) {
    _appState.clear();
    await _windowService.hidePreview();
    return;
  }

  // Get the device pixel ratio from the captured image vs screen
  // The fullscreen image is in physical pixels; the selection rect is in logical pixels
  final imgSize = await _getImageSize(fullScreenBytes);
  final display = await ScreenRetriever.instance.getPrimaryDisplay();
  final screenSize = display.size;

  final scaleX = imgSize.width / screenSize.width;
  final scaleY = imgSize.height / screenSize.height;

  final physicalRect = Rect.fromLTRB(
    logicalRect.left * scaleX,
    logicalRect.top * scaleY,
    logicalRect.right * scaleX,
    logicalRect.bottom * scaleY,
  );

  final cropped = await _captureService.cropImage(
    fullScreenBytes,
    physicalRect,
  );
  if (cropped != null) {
    _appState.setCapturedImage(cropped);
    await _windowService.showPreviewInPlace(selectionRect: logicalRect);
  } else {
    _appState.clear();
    await _windowService.hidePreview();
  }
}

Future<void> _handleRegionCancel() async {
  _appState.clear();
  await _windowService.hidePreview();
}

Future<void> _handleCopy() async {
  final bytes = _appState.screenshotBytes;
  if (bytes != null) {
    await _clipboardService.copyImage(bytes);
  }
  _appState.clear();
  await _windowService.hidePreview();
}

Future<void> _handleSave() async {
  final bytes = _appState.screenshotBytes;
  if (bytes != null) {
    await _fileService.saveScreenshot(bytes);
  }
  _appState.clear();
  await _windowService.hidePreview();
}

Future<void> _handleDiscard() async {
  _appState.clear();
  await _windowService.hidePreview();
}

Future<void> _handleQuit() async {
  await _hotkeyService.unregisterAll();
  await _trayService.destroy();
  await windowManager.destroy();
  exit(0);
}
