import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'services/capture_service.dart';
import 'services/clipboard_service.dart';
import 'services/file_service.dart';
import 'services/hotkey_service.dart';
import 'services/scroll_capture_service.dart';
import 'services/tray_service.dart';
import 'services/window_service.dart';
import 'state/app_state.dart';

bool _displayChangeInProgress = false;
bool _displayChangePending = false;
bool _regionCaptureCancelled = false;
bool _escActionInProgress = false;

/// Pre-cached window/element rects from background polling.
/// Updated every ~2 seconds by the native background thread.
/// Rects are in global CG coordinates (top-left origin).
List<DetectedWindow> _cachedGlobalWindows = [];

/// Per-display cache of screenshot + local rects, keyed by CG origin string.
/// Lives only for the duration of one capture session (cleared on dismiss/finish).
class _DisplayCache {
  final List<Rect> localRects;
  const _DisplayCache({required this.localRects});
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
late final ScrollCaptureService _scrollCaptureService;
late final WindowService _windowService;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  _appState = AppState();
  _captureService = CaptureService();
  _clipboardService = ClipboardService();
  _fileService = FileService();
  _hotkeyService = HotkeyService();
  _scrollCaptureService = ScrollCaptureService();
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
      onHitTest: _handleHitTest,
      onScrollCancel: _handleScrollCancel,
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
  _windowService.onEscPressed = _handleEscPressed;
  _windowService.onRectsUpdated = (windows) {
    _cachedGlobalWindows = windows;
  };

  await _trayService.init();
  _trayService.onCaptureFullScreen = _handleFullScreenCapture;
  _trayService.onCaptureRegion = _handleRegionCapture;
  _trayService.onCaptureScroll = _handleScrollCapture;
  _trayService.onQuit = _handleQuit;

  await _hotkeyService.register(
    onFullScreen: _handleFullScreenCapture,
    onRegion: _handleRegionCapture,
    onScrollCapture: _handleScrollCapture,
  );

  // Start background rect polling — keeps window/element rects ready
  // so captures are instant (no AX tree walk at trigger time).
  await _windowService.startRectPolling();
}

void _handleEscPressed() {
  switch (_appState.status) {
    case CaptureStatus.capturing:
      // During capture setup, Esc should abort the flow immediately.
      _regionCaptureCancelled = true;
      return;
    case CaptureStatus.selecting:
      // Fallback: region overlay normally handles Esc in Flutter.
      if (_escActionInProgress) return;
      _escActionInProgress = true;
      unawaited(
        _handleRegionCancel().whenComplete(() {
          _escActionInProgress = false;
        }),
      );
      return;
    case CaptureStatus.captured:
      if (_escActionInProgress) return;
      _escActionInProgress = true;
      unawaited(
        _handleDiscard().whenComplete(() {
          _escActionInProgress = false;
        }),
      );
      return;
    case CaptureStatus.scrollWaiting:
      if (_escActionInProgress) return;
      _escActionInProgress = true;
      unawaited(
        _handleScrollCancel().whenComplete(() {
          _escActionInProgress = false;
        }),
      );
      return;
    case CaptureStatus.scrollCapturing:
      // Signal loop to stop; loop handles partial result logic
      _scrollCaptureService.requestCancel();
      return;
    case CaptureStatus.idle:
      return;
  }
}

/// Decode raw BGRA pixel bytes into a ui.Image via GPU upload.
/// Near-instant compared to PNG codec decode.
Future<ui.Image> _decodeRawPixels(ScreenCapture capture) {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    capture.bytes,
    capture.pixelWidth,
    capture.pixelHeight,
    ui.PixelFormat.bgra8888,
    completer.complete,
    rowBytes: capture.bytesPerRow,
  );
  return completer.future;
}

Future<void> _showPreviewWithImage(
  ui.Image image, {
  required Size targetScreenSize,
  required Offset targetScreenOrigin,
}) async {
  _appState.setCapturedImage(image);
  await _windowService.showPreview(
    imageWidth: image.width,
    imageHeight: image.height,
    screenSize: targetScreenSize,
    screenOrigin: targetScreenOrigin,
  );
  // setCapturedImage() happens before the window is visible. Rebuild once more
  // after show/focus so PreviewScreen can re-run focus sync reliably.
  _appState.nudge();
  await _windowService.startEscMonitor();
}

/// Real-time AX hit-test: convert local overlay coordinates to global CG
/// coordinates, query the deepest accessible element, and return the result
/// back in local coordinates.
Future<Rect?> _handleHitTest(Offset localPoint) async {
  final screenOrigin = _appState.screenOrigin;
  if (screenOrigin == null) return null;

  final cgPoint = Offset(
    localPoint.dx + screenOrigin.dx,
    localPoint.dy + screenOrigin.dy,
  );
  final cgRect = await _windowService.hitTestElement(cgPoint);
  if (cgRect == null) return null;

  // Convert CG rect back to local overlay coordinates.
  return cgRect.shift(Offset(-screenOrigin.dx, -screenOrigin.dy));
}

Future<void> _handleFullScreenCapture() async {
  if (_appState.status == CaptureStatus.capturing) return;
  _escActionInProgress = false;
  await _windowService.stopEscMonitor();
  _appState.setCapturing();
  await _windowService.hidePreview();

  // Native capture targets the display under the cursor
  final capture = await _windowService.captureScreen();
  if (capture != null) {
    final decodedImage = await _decodeRawPixels(capture);
    await _showPreviewWithImage(
      decodedImage,
      targetScreenSize: capture.screenSize,
      targetScreenOrigin: capture.screenOrigin,
    );
  } else {
    _appState.clear();
  }
}

Future<void> _handleRegionCapture() async {
  if (_appState.status == CaptureStatus.capturing) return;
  _escActionInProgress = false;
  await _windowService.stopEscMonitor();
  // Allow re-entry from selecting state (display-change re-trigger).
  _appState.setCapturing();
  _regionCaptureCancelled = false;
  await _windowService.hidePreview();
  _clearDisplayCaches();

  // Start native Esc monitor so user can cancel during capture setup
  // (before the Flutter overlay and its KeyboardListener are visible).
  await _windowService.startEscMonitor();

  // Stop background polling — our overlay would contaminate future polls.
  await _windowService.stopRectPolling();

  // Capture the display under the cursor for single-display overlay.
  final capture = await _windowService.captureScreen();

  // Bail if user pressed Esc during capture.
  if (_regionCaptureCancelled) {
    _regionCaptureCancelled = false;
    _appState.clear();
    await _windowService.stopEscMonitor();
    await _windowService.startRectPolling();
    return;
  }

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
      localRects: localRects,
    );

    // Decode raw BGRA pixels — near-instant GPU upload (no PNG codec).
    final decodedImage = await _decodeRawPixels(capture);

    // Bail if user pressed Esc during decode — we own the image, dispose it.
    if (_regionCaptureCancelled) {
      _regionCaptureCancelled = false;
      decodedImage.dispose();
      _appState.clear();
      await _windowService.stopEscMonitor();
      await _windowService.startRectPolling();
      return;
    }

    _appState.setSelecting(
      decodedImage: decodedImage,
      windowRects: localRects,
      screenSize: capture.screenSize,
      screenOrigin: capture.screenOrigin,
    );

    // Enter overlay mode — window configured + positioned but stays invisible.
    await _windowService.showFullScreenOverlay(
      screenOrigin: capture.screenOrigin,
    );

    // Bail if user pressed Esc during overlay setup.
    if (_regionCaptureCancelled) {
      _regionCaptureCancelled = false;
      _appState.clear();
      await _windowService.exitOverlay();
      await _windowService.stopEscMonitor();
      await _windowService.startRectPolling();
      return;
    }

    // Wait for Flutter to render the pre-decoded image at overlay size.
    await WidgetsBinding.instance.endOfFrame;
    await WidgetsBinding.instance.endOfFrame;

    // Bail if user pressed Esc during frame wait.
    if (_regionCaptureCancelled) {
      _regionCaptureCancelled = false;
      _appState.clear();
      await _windowService.exitOverlay();
      await _windowService.stopEscMonitor();
      await _windowService.startRectPolling();
      return;
    }

    await _windowService.revealOverlay();
    // Overlay is visible — Flutter KeyboardListener takes over Esc handling.
    await _windowService.stopEscMonitor();
  } else {
    _appState.clear();
    await _windowService.stopEscMonitor();
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
      await _windowService.exitOverlay();
      await _windowService.startRectPolling();
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
      _displayCaches[key] = _DisplayCache(localRects: localRects);
    } else {
      localRects = const [];
    }

    // 4. Decode raw BGRA pixels — near-instant GPU upload.
    final decodedImage = await _decodeRawPixels(capture);

    // 5. Move the invisible overlay to the new display (setFrame only).
    await _windowService.repositionOverlay(screenOrigin: capture.screenOrigin);

    // 6. Update Flutter state with the pre-decoded image.
    _appState.setSelecting(
      decodedImage: decodedImage,
      windowRects: localRects,
      screenSize: capture.screenSize,
      screenOrigin: capture.screenOrigin,
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
      _displayCaches[key] = _DisplayCache(localRects: fetchedRects);
      _appState.updateWindowRects(fetchedRects);
    }
  } finally {
    _displayChangeInProgress = false;
    if (_displayChangePending) {
      _displayChangePending = false;
      unawaited(_handleDisplayChanged());
    }
  }
}

Future<void> _handleRegionSelected(Rect logicalRect) async {
  final decodedFullScreen = _appState.decodedFullScreen;
  final screenSize = _appState.screenSize;
  final screenOrigin = _appState.screenOrigin;
  if (decodedFullScreen == null || screenSize == null || screenOrigin == null) {
    _appState.clear();
    await _windowService.hidePreview();
    return;
  }

  // The decoded image is in physical pixels; the selection rect is in logical pixels.
  final scaleX = decodedFullScreen.width / screenSize.width;
  final scaleY = decodedFullScreen.height / screenSize.height;

  final physicalRect = Rect.fromLTRB(
    logicalRect.left * scaleX,
    logicalRect.top * scaleY,
    logicalRect.right * scaleX,
    logicalRect.bottom * scaleY,
  );

  // Stop Esc monitor during crop to prevent a race where Esc disposes the
  // source image while cropImage's picture.toImage() is still in-flight.
  await _windowService.stopEscMonitor();

  final cropped = await _captureService.cropImage(
    decodedFullScreen,
    physicalRect,
  );
  if (cropped != null) {
    // Full-screen selection → centered preview (same as ⌘⇧1)
    // Partial selection → borderless in-place preview at the selection location
    final isFullScreen =
        logicalRect.left <= 4 &&
        logicalRect.top <= 4 &&
        logicalRect.right >= screenSize.width - 4 &&
        logicalRect.bottom >= screenSize.height - 4;

    if (isFullScreen) {
      await _showPreviewWithImage(
        cropped,
        targetScreenSize: screenSize,
        targetScreenOrigin: screenOrigin,
      );
    } else {
      _appState.setCapturedImage(cropped);
      await _windowService.showPreviewInPlace(selectionRect: logicalRect);
      // Window is resized/focused after setCapturedImage(); force another
      // rebuild so KeyboardListener focus sync runs with the visible window.
      _appState.nudge();
      await _windowService.startEscMonitor();
    }
  } else {
    _appState.clear();
    await _windowService.stopEscMonitor();
    await _windowService.hidePreview();
  }
}

Future<void> _handleRegionCancel() async {
  // Clear state and hide immediately for instant visual feedback.
  _appState.clear();
  await _windowService.hidePreview();
  // Clean up overlay properties (monitors, level, isOpaque, etc.).
  // Without this, the display-change monitor stays active after cancel,
  // and the window retains borderless/maximumWindow configuration.
  await _windowService.exitOverlay();
  _clearDisplayCaches();
  unawaited(_windowService.stopEscMonitor());
  unawaited(_windowService.startRectPolling());
}

Future<void> _handleCopy() async {
  _escActionInProgress = false;
  // Detach image so clear() won't dispose it, then hide immediately.
  final image = _appState.detachCapturedImage();
  _appState.clear();
  await _windowService.hidePreview();
  // Encode + copy after window is gone — user perceives instant dismiss.
  if (image != null) {
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    if (byteData != null) {
      await _clipboardService.copyImage(byteData.buffer.asUint8List());
    }
    image.dispose();
  }
  _clearDisplayCaches();
  unawaited(_windowService.stopEscMonitor());
  unawaited(_windowService.startRectPolling());
}

Future<void> _handleSave() async {
  _escActionInProgress = false;
  // Detach image so clear() won't dispose it, then hide immediately.
  final image = _appState.detachCapturedImage();
  _appState.clear();
  await _windowService.hidePreview();
  // Encode + save after window is gone — user perceives instant dismiss.
  if (image != null) {
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    if (byteData != null) {
      await _fileService.saveScreenshot(byteData.buffer.asUint8List());
    }
    image.dispose();
  }
  _clearDisplayCaches();
  unawaited(_windowService.stopEscMonitor());
  unawaited(_windowService.startRectPolling());
}

Future<void> _handleDiscard() async {
  _escActionInProgress = false;
  // Hide window immediately for instant visual feedback.
  _appState.clear();
  await _windowService.hidePreview();
  // Non-blocking cleanup after window is gone.
  _clearDisplayCaches();
  unawaited(_windowService.stopEscMonitor());
  unawaited(_windowService.startRectPolling());
}

Future<void> _handleScrollCapture() async {
  if (_appState.status == CaptureStatus.capturing ||
      _appState.status == CaptureStatus.scrollWaiting ||
      _appState.status == CaptureStatus.scrollCapturing) {
    return;
  }
  _escActionInProgress = false;
  await _windowService.stopEscMonitor();
  _appState.setCapturing();
  await _windowService.hidePreview();

  _appState.setScrollWaiting();
  _windowService.onScrollTargetClicked = _handleScrollTargetClicked;
  await _windowService.startClickMonitor();
  await _windowService.startEscMonitor();
}

Future<void> _handleScrollTargetClicked(Offset cgPoint) async {
  await _windowService.stopClickMonitor();
  await _windowService.stopEscMonitor();

  final target = await _windowService.hitTestScrollTarget(cgPoint);
  if (target == null) {
    _appState.clear();
    await _windowService.hidePreview();
    await _windowService.startRectPolling();
    return;
  }

  _appState.setScrollCapturing(targetBounds: target.bounds);
  await _windowService.showScrollBadge(anchorRect: target.bounds);

  _scrollCaptureService.onProgress = _appState.updateScrollFrameCount;
  await _windowService.startEscMonitor();

  final result = await _scrollCaptureService.captureScrolling(
    windowId: target.windowId,
    windowBounds: target.bounds,
    windowService: _windowService,
  );

  await _windowService.stopEscMonitor();

  if (result != null) {
    _appState.setCapturedScrollImage(result);
    await _windowService.showScrollPreview(
      imageWidth: result.width,
      imageHeight: result.height,
      screenSize: Size(target.bounds.width, target.bounds.height),
      screenOrigin: Offset(target.bounds.left, target.bounds.top),
    );
    _appState.nudge();
    await _windowService.startEscMonitor();
  } else {
    _appState.clear();
    await _windowService.hidePreview();
    await _windowService.startRectPolling();
  }
}

Future<void> _handleScrollCancel() async {
  await _windowService.stopClickMonitor();
  _scrollCaptureService.requestCancel();
  _appState.clear();
  await _windowService.hidePreview();
  unawaited(_windowService.stopEscMonitor());
  unawaited(_windowService.startRectPolling());
}

Future<void> _handleQuit() async {
  await _windowService.stopEscMonitor();
  await _windowService.stopRectPolling();
  await _hotkeyService.unregisterAll();
  await _trayService.destroy();
  await windowManager.destroy();
  exit(0);
}
