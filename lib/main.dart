import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'services/capture_service.dart';
import 'services/clipboard_service.dart';
import 'services/file_service.dart';
import 'services/hotkey_service.dart';
import 'services/tray_service.dart';
import 'services/window_service.dart';
import 'state/app_state.dart';

bool _displayChangeInProgress = false;
bool _displayChangePending = false;

/// Pre-cached window/element rects from background polling.
/// Updated every ~2 seconds by the native background thread.
/// Rects are in global CG coordinates (top-left origin).
List<DetectedWindow> _cachedGlobalWindows = [];

/// Per-display cache of screenshot + local rects, keyed by CG origin string.
/// Lives only for the duration of one capture session (cleared on dismiss/finish).
class _DisplayCache {
  final ScreenCapture capture;
  final List<Rect> localRects;
  const _DisplayCache({required this.capture, required this.localRects});
}

final Map<String, _DisplayCache> _displayCaches = {};

String _displayKey(Offset origin) => '${origin.dx},${origin.dy}';

void _clearDisplayCaches() {
  _displayCaches.clear();
}

/// Convert globally-cached window rects to local coordinates for a display.
List<Rect> _globalRectsToLocal(Offset screenOrigin) {
  final ox = screenOrigin.dx;
  final oy = screenOrigin.dy;
  return _cachedGlobalWindows
      .map((w) => w.rect.shift(Offset(-ox, -oy)))
      .toList();
}

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

  _windowService.onOverlayCancelled = _handleRegionCancel;
  _windowService.onOverlayDisplayChanged = _handleDisplayChanged;
  _windowService.onRectsUpdated = (windows) {
    _cachedGlobalWindows = windows;
  };

  await _trayService.init();
  _trayService.onCaptureFullScreen = _handleFullScreenCapture;
  _trayService.onCaptureRegion = _handleRegionCapture;
  _trayService.onQuit = _handleQuit;

  await _hotkeyService.register(
    onFullScreen: _handleFullScreenCapture,
    onRegion: _handleRegionCapture,
  );

  // Start background rect polling — keeps window/element rects ready
  // so captures are instant (no AX tree walk at trigger time).
  await _windowService.startRectPolling();
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

/// Decode PNG bytes into a ui.Image. Caller owns the returned image.
Future<ui.Image> _decodeImageBytes(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  codec.dispose();
  return frame.image;
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

  // Native capture targets the display under the cursor
  final capture = await _windowService.captureScreen();
  if (capture != null) {
    await _showPreviewWithImage(capture.bytes);
  } else {
    _appState.clear();
  }
}

Future<void> _handleRegionCapture() async {
  if (_appState.status == CaptureStatus.capturing) return;
  // Allow re-entry from selecting state (display-change re-trigger).
  _appState.setCapturing();
  await _windowService.hidePreview();
  _clearDisplayCaches();

  // Stop background polling — our overlay would contaminate future polls.
  await _windowService.stopRectPolling();

  // Capture the display under the cursor for single-display overlay.
  final capture = await _windowService.captureScreen();
  if (capture != null) {
    List<Rect> localRects;

    if (_cachedGlobalWindows.isNotEmpty) {
      // Use pre-cached rects (instant — no AX tree walk needed).
      localRects = _globalRectsToLocal(capture.screenOrigin);
    } else {
      // Cold start fallback — synchronous fetch (first capture ever).
      final windows = await _windowService.getWindowList();
      localRects = windows
          .map(
            (w) => w.rect.shift(
              Offset(-capture.screenOrigin.dx, -capture.screenOrigin.dy),
            ),
          )
          .toList();
    }

    // Cache for this display so switching back is instant.
    _displayCaches[_displayKey(capture.screenOrigin)] = _DisplayCache(
      capture: capture,
      localRects: localRects,
    );

    // Pre-decode PNG so Flutter can paint immediately via RawImage
    // (no async Image.memory decode that would show stale content).
    final decodedImage = await _decodeImageBytes(capture.bytes);

    _appState.setSelecting(
      capture.bytes,
      decodedImage: decodedImage,
      windowRects: localRects,
      screenSize: capture.screenSize,
    );

    // Enter overlay mode — window configured + positioned but stays invisible.
    await _windowService.showFullScreenOverlay(
      screenOrigin: capture.screenOrigin,
    );

    // Wait for Flutter to render the pre-decoded image at overlay size.
    await WidgetsBinding.instance.endOfFrame;
    await WidgetsBinding.instance.endOfFrame;
    await _windowService.revealOverlay();
  } else {
    _appState.clear();
    await _windowService.startRectPolling();
  }
}

/// Called when the cursor moves to a different display during overlay mode.
/// Uses fast suspend/resume path (no window property restore/reconfigure)
/// and pre-cached global rects for instant display switching.
Future<void> _handleDisplayChanged() async {
  if (_appState.status != CaptureStatus.selecting) return;

  if (_displayChangeInProgress) {
    _displayChangePending = true;
    return;
  }
  _displayChangeInProgress = true;

  try {
    // 1. Hide overlay (fast — keeps borderless/maximumWindow config).
    await _windowService.suspendOverlay();

    // 2. Capture the new display.
    final capture = await _windowService.captureScreen();
    if (capture == null) {
      _appState.clear();
      return;
    }

    // 3. Check per-session display cache first, then global pre-cached rects.
    final key = _displayKey(capture.screenOrigin);
    final cached = _displayCaches[key];
    final List<Rect> localRects;

    if (cached != null) {
      localRects = cached.localRects;
    } else if (_cachedGlobalWindows.isNotEmpty) {
      localRects = _globalRectsToLocal(capture.screenOrigin);
      _displayCaches[key] = _DisplayCache(
        capture: capture,
        localRects: localRects,
      );
    } else {
      localRects = const [];
    }

    // 4. Pre-decode the new screenshot so RawImage can paint it instantly.
    final decodedImage = await _decodeImageBytes(capture.bytes);

    // 5. Move the invisible overlay to the new display (setFrame only).
    await _windowService.repositionOverlay(screenOrigin: capture.screenOrigin);

    // 6. Update Flutter state with the pre-decoded image.
    _appState.setSelecting(
      capture.bytes,
      decodedImage: decodedImage,
      windowRects: localRects,
      screenSize: capture.screenSize,
    );

    // 7. Wait for Flutter to render the new (pre-decoded) screenshot.
    await WidgetsBinding.instance.endOfFrame;
    await WidgetsBinding.instance.endOfFrame;

    // 8. Reveal overlay — Flutter has already painted the correct content.
    await _windowService.revealOverlay();

    // 9. If we had no rects at all, fetch synchronously as fallback.
    if (localRects.isEmpty && _cachedGlobalWindows.isEmpty) {
      final windows = await _windowService.getWindowList();
      final fetchedRects = windows
          .map(
            (w) => w.rect.shift(
              Offset(-capture.screenOrigin.dx, -capture.screenOrigin.dy),
            ),
          )
          .toList();
      _displayCaches[key] = _DisplayCache(
        capture: capture,
        localRects: fetchedRects,
      );
      _appState.updateWindowRects(fetchedRects);
    }
  } finally {
    _displayChangeInProgress = false;
    if (_displayChangePending) {
      _displayChangePending = false;
      _handleDisplayChanged();
    }
  }
}

Future<void> _handleRegionSelected(Rect logicalRect) async {
  final fullScreenBytes = _appState.fullScreenBytes;
  final screenSize = _appState.screenSize;
  if (fullScreenBytes == null || screenSize == null) {
    _appState.clear();
    await _windowService.hidePreview();
    return;
  }

  // Get the device pixel ratio from the captured image vs the captured display.
  // The image is in physical pixels; the selection rect is in logical pixels.
  final imgSize = await _getImageSize(fullScreenBytes);

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
  _clearDisplayCaches();
  _appState.clear();
  await _windowService.hidePreview();
  await _windowService.startRectPolling();
}

Future<void> _handleCopy() async {
  final bytes = _appState.screenshotBytes;
  if (bytes != null) {
    await _clipboardService.copyImage(bytes);
  }
  _clearDisplayCaches();
  _appState.clear();
  await _windowService.hidePreview();
  await _windowService.startRectPolling();
}

Future<void> _handleSave() async {
  final bytes = _appState.screenshotBytes;
  if (bytes != null) {
    await _fileService.saveScreenshot(bytes);
  }
  _clearDisplayCaches();
  _appState.clear();
  await _windowService.hidePreview();
  await _windowService.startRectPolling();
}

Future<void> _handleDiscard() async {
  _clearDisplayCaches();
  _appState.clear();
  await _windowService.hidePreview();
  await _windowService.startRectPolling();
}

Future<void> _handleQuit() async {
  await _windowService.stopRectPolling();
  await _hotkeyService.unregisterAll();
  await _trayService.destroy();
  await windowManager.destroy();
  exit(0);
}
