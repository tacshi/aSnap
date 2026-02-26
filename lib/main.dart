import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'models/annotation.dart';
import 'services/capture_service.dart';
import 'services/clipboard_service.dart';
import 'services/file_service.dart';
import 'services/hotkey_service.dart';
import 'services/scroll_capture_service.dart';
import 'services/tray_service.dart';
import 'services/window_service.dart';
import 'state/annotation_state.dart';
import 'state/app_state.dart';
import 'utils/annotation_compositor.dart';

bool _displayChangeInProgress = false;
bool _displayChangePending = false;
bool _regionCaptureCancelled = false;
bool _escActionInProgress = false;

/// Keeps the pinned `ui.Image` alive in Dart memory for fast re-edit via
/// Space (avoids round-tripping image bytes through the platform channel).
ui.Image? _pinnedFlutterImage;

/// Last captured/copied image kept alive for deferred pinning.
/// Allows "capture → copy → pin" workflow: copy clears the preview but this
/// reference survives so a subsequent Pin command can still pin the image.
ui.Image? _lastCopiedImage;

/// CG-coordinate frame of the last copied image (for pin placement).
Rect? _lastCopiedCgFrame;

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
late final AnnotationState _annotationState;
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
  _annotationState = AnnotationState();
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
      annotationState: _annotationState,
      windowService: _windowService,
      onCopy: _handleCopy,
      onSave: _handleSave,
      onPin: _handlePin,
      onDiscard: _handleDiscard,
      onRegionSelected: _handleRegionSelected,
      onRegionCopy: _handleRegionCopy,
      onRegionSave: _handleRegionSave,
      onRegionPin: _handleRegionPin,
      onScrollRegionSelected: _handleScrollRegionSelected,
      onRegionCancel: _handleRegionCancel,
      onHitTest: _handleHitTest,
      onScrollCaptureDone: _handleScrollCaptureDone,
      onScrollStopButtonRect: _handleScrollStopButtonRect,
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
    await _windowService.checkAccessibility(prompt: true);
  }

  _windowService.onOverlayCancelled = () {
    // Ignore native cancel signals while an explicit user action (Done/Esc)
    // is already being processed to avoid tearing down the next preview state.
    if (_escActionInProgress) return;

    if (_appState.status == CaptureStatus.scrollCapturing) {
      _escActionInProgress = true;
      unawaited(
        _handleScrollCancel().whenComplete(() {
          _escActionInProgress = false;
        }),
      );
      return;
    }

    if (_appState.status == CaptureStatus.selecting ||
        _appState.status == CaptureStatus.scrollSelecting) {
      unawaited(_handleRegionCancel());
    }
  };
  _windowService.onOverlayDisplayChanged = _handleDisplayChanged;
  _windowService.onEscPressed = _handleEscPressed;
  _windowService.onScrollCaptureDone = _handleScrollCaptureDone;
  _windowService.onRectsUpdated = (windows) {
    _cachedGlobalWindows = windows;
  };

  _windowService.onEditPinnedImage = _handleEditPinnedImage;
  _windowService.onPinnedImageClosed = _handlePinnedImageClosed;

  await _trayService.init();
  _trayService.onCaptureFullScreen = _handleFullScreenCapture;
  _trayService.onCaptureRegion = _handleRegionCapture;
  _trayService.onCaptureScroll = _handleScrollCapture;
  _trayService.onPin = _handlePin;
  _trayService.onQuit = _handleQuit;

  await _hotkeyService.register(
    onFullScreen: _handleFullScreenCapture,
    onRegion: _handleRegionCapture,
    onScrollCapture: _handleScrollCapture,
    onPin: _handlePin,
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
    case CaptureStatus.scrollSelecting:
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
    case CaptureStatus.scrollResult:
      if (_escActionInProgress) return;
      _escActionInProgress = true;
      unawaited(
        _handleDiscard().whenComplete(() {
          _escActionInProgress = false;
        }),
      );
      return;
    case CaptureStatus.scrollCapturing:
      // Esc during scroll capture = cancel (discard frames)
      if (_escActionInProgress) return;
      _escActionInProgress = true;
      unawaited(
        _handleScrollCancel().whenComplete(() {
          _escActionInProgress = false;
        }),
      );
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
  // No native Esc monitor for captured state — PreviewScreen uses
  // HardwareKeyboard for focus-independent Escape handling (supports
  // unwinding shapes mode before dismiss).
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
  _lastCopiedImage?.dispose();
  _lastCopiedImage = null;
  _lastCopiedCgFrame = null;
  await _windowService.stopEscMonitor();
  _annotationState.clear();
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
  _lastCopiedImage?.dispose();
  _lastCopiedImage = null;
  _lastCopiedCgFrame = null;
  await _windowService.stopEscMonitor();
  // Allow re-entry from selecting state (display-change re-trigger).
  _annotationState.clear();
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
      await _windowService.hidePreview();
      _appState.clear();
      await _windowService.cleanupOverlay();
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
      await _windowService.hidePreview();
      _appState.clear();
      await _windowService.cleanupOverlay();
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
  if (_appState.status != CaptureStatus.selecting &&
      _appState.status != CaptureStatus.scrollSelecting) {
    return;
  }

  if (_windowService.overlaySelectionActive) {
    await _handleRegionCancel();
    return;
  }

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
      await _windowService.hidePreview();
      _appState.clear();
      await _windowService.cleanupOverlay();
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
    // Preserve the current status (selecting or scrollSelecting).
    if (_appState.status == CaptureStatus.scrollSelecting) {
      _appState.setScrollSelecting(
        decodedImage: decodedImage,
        windowRects: localRects,
        screenSize: capture.screenSize,
        screenOrigin: capture.screenOrigin,
      );
    } else {
      _appState.setSelecting(
        decodedImage: decodedImage,
        windowRects: localRects,
        screenSize: capture.screenSize,
        screenOrigin: capture.screenOrigin,
      );
    }

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
  _windowService.overlaySelectionActive = false;
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
      // rebuild so focus sync runs with the visible window.
      _appState.nudge();
      // No native Esc monitor — PreviewScreen handles Escape via
      // HardwareKeyboard (supports shapes mode unwinding).
    }
  } else {
    _appState.clear();
    await _windowService.stopEscMonitor();
    await _windowService.hidePreview();
  }
}

/// Copy the selected region directly from the overlay (Snipaste-style).
/// Hides the overlay instantly, then crops + encodes + copies in the background.
/// Uses suspendOverlay (not exitOverlay) to avoid a full-screen flash caused by
/// styleMask restoration while dismissing the overlay.
Future<void> _handleRegionCopy(Rect logicalRect) async {
  _windowService.overlaySelectionActive = false;
  final decodedFullScreen = _appState.decodedFullScreen;
  final screenSize = _appState.screenSize;
  final screenOrigin = _appState.screenOrigin;
  if (decodedFullScreen == null || screenSize == null || screenOrigin == null) {
    _appState.clear();
    await _windowService.hidePreview();
    return;
  }

  final scaleX = decodedFullScreen.width / screenSize.width;
  final scaleY = decodedFullScreen.height / screenSize.height;
  final physicalRect = Rect.fromLTRB(
    logicalRect.left * scaleX,
    logicalRect.top * scaleY,
    logicalRect.right * scaleX,
    logicalRect.bottom * scaleY,
  );

  // CG frame for deferred pinning (preserve selection position/size).
  final cgPinFrame = Rect.fromLTWH(
    logicalRect.left + screenOrigin.dx,
    logicalRect.top + screenOrigin.dy,
    logicalRect.width,
    logicalRect.height,
  );

  // Capture annotation state before clearing.
  final annotations = _annotationState.annotations;

  // Detach the image so clear() won't dispose it — we need it for cropping.
  _appState.detachDecodedFullScreen();

  // Hide FIRST — user perceives instant dismiss.
  await _windowService.hidePreview();
  _appState.clear();
  _annotationState.clear();
  _clearDisplayCaches();
  unawaited(_windowService.stopEscMonitor());
  unawaited(_windowService.suspendOverlay());
  unawaited(_windowService.startRectPolling());

  // Expensive work after the window is gone.
  var cropped = await _captureService.cropImage(
    decodedFullScreen,
    physicalRect,
  );
  if (cropped != null) {
    if (annotations.isNotEmpty) {
      final composited = await compositeAnnotations(cropped, annotations);
      cropped.dispose();
      cropped = composited;
    }
    final byteData = await cropped.toByteData(format: ui.ImageByteFormat.png);
    if (byteData != null) {
      await _clipboardService.copyImage(byteData.buffer.asUint8List());
    }
    // Keep the final image alive for deferred pinning ("capture → copy → pin").
    _lastCopiedImage?.dispose();
    _lastCopiedImage = cropped;
    _lastCopiedCgFrame = cgPinFrame;
  }
  decodedFullScreen.dispose();
}

/// Save the selected region directly from the overlay (Snipaste-style).
/// Shows the save dialog while the overlay is visible (selection stays behind
/// the sheet). If the user cancels, returns to selection mode.  If they pick
/// a path, hides the overlay instantly, then crops + encodes + writes.
Future<void> _handleRegionSave(Rect logicalRect) async {
  _windowService.overlaySelectionActive = false;
  // Show save dialog WHILE overlay is visible — selection stays behind the
  // NSSavePanel sheet so the user sees what they're saving.
  final savePath = await _fileService.showSaveDialog();
  if (savePath == null) return; // User cancelled — stay in selection mode.

  // User picked a path — proceed with hide + crop + save.
  final decodedFullScreen = _appState.decodedFullScreen;
  final screenSize = _appState.screenSize;
  if (decodedFullScreen == null || screenSize == null) {
    _appState.clear();
    await _windowService.hidePreview();
    return;
  }

  final scaleX = decodedFullScreen.width / screenSize.width;
  final scaleY = decodedFullScreen.height / screenSize.height;
  final physicalRect = Rect.fromLTRB(
    logicalRect.left * scaleX,
    logicalRect.top * scaleY,
    logicalRect.right * scaleX,
    logicalRect.bottom * scaleY,
  );

  // Capture annotation state before clearing.
  final annotations = _annotationState.annotations;

  // Detach the image so clear() won't dispose it — we need it for cropping.
  _appState.detachDecodedFullScreen();

  // Hide overlay instantly — user perceives instant dismiss after save dialog.
  await _windowService.hidePreview();
  _appState.clear();
  _annotationState.clear();
  _clearDisplayCaches();
  unawaited(_windowService.stopEscMonitor());
  unawaited(_windowService.cleanupOverlay());
  unawaited(_windowService.startRectPolling());

  // Expensive crop + encode + write after the window is gone.
  var cropped = await _captureService.cropImage(
    decodedFullScreen,
    physicalRect,
  );
  if (cropped != null) {
    if (annotations.isNotEmpty) {
      final composited = await compositeAnnotations(cropped, annotations);
      cropped.dispose();
      cropped = composited;
    }
    final byteData = await cropped.toByteData(format: ui.ImageByteFormat.png);
    if (byteData != null) {
      await _fileService.saveToPath(savePath, byteData.buffer.asUint8List());
    }
    cropped.dispose();
  }
  decodedFullScreen.dispose();
}

Future<void> _handleRegionCancel() async {
  _windowService.overlaySelectionActive = false;
  // Hide window BEFORE clearing state — instant dismiss.
  await _windowService.hidePreview();
  _appState.clear();
  _annotationState.clear();
  _clearDisplayCaches();
  // Intentionally defer overlay cleanup to the next show transition.
  // Immediate cleanup here can cause a visible flash on close.
  unawaited(_windowService.stopEscMonitor());
  unawaited(_windowService.startRectPolling());
}

Future<void> _handleCopy() async {
  _escActionInProgress = false;
  final wasScrollResult = _appState.status == CaptureStatus.scrollResult;
  // Detach image so clear() won't dispose it.
  final image = _appState.detachCapturedImage();
  final annotations = _annotationState.annotations;
  Rect? copyCgFrame;
  if (image != null) {
    final windowPos = await windowManager.getPosition();
    final windowSize = await windowManager.getSize();
    copyCgFrame = Rect.fromLTWH(
      windowPos.dx,
      windowPos.dy,
      windowSize.width,
      windowSize.height,
    );
  }
  // Hide window BEFORE clearing state.
  await _windowService.hidePreview();
  _appState.clear();
  _annotationState.clear();
  // Encode + copy after window is gone — user perceives instant dismiss.
  if (image != null) {
    final finalImage = annotations.isNotEmpty
        ? await compositeAnnotations(image, annotations)
        : image;
    final byteData = await finalImage.toByteData(
      format: ui.ImageByteFormat.png,
    );
    if (byteData != null) {
      await _clipboardService.copyImage(byteData.buffer.asUint8List());
    }
    // Keep the final image alive for deferred pinning ("capture → copy → pin").
    // Dispose the previous one if any, and the original if we composited.
    _lastCopiedImage?.dispose();
    if (!identical(finalImage, image)) {
      image.dispose();
      _lastCopiedImage = finalImage;
    } else {
      _lastCopiedImage = image;
    }
    _lastCopiedCgFrame = copyCgFrame;
  } else {
    _lastCopiedCgFrame = null;
  }
  _clearDisplayCaches();
  unawaited(_windowService.stopEscMonitor());
  if (wasScrollResult) unawaited(_windowService.cleanupOverlay());
  unawaited(_windowService.startRectPolling());
}

Future<void> _handleSave() async {
  _escActionInProgress = false;
  final wasScrollResult = _appState.status == CaptureStatus.scrollResult;
  // Composite annotations if any, then encode.
  final image = _appState.capturedImage;
  final annotations = _annotationState.annotations;
  if (image != null && annotations.isNotEmpty) {
    final composited = await compositeAnnotations(image, annotations);
    final byteData = await composited.toByteData(
      format: ui.ImageByteFormat.png,
    );
    if (byteData != null) {
      await _fileService.saveScreenshot(byteData.buffer.asUint8List());
    }
    composited.dispose();
  } else {
    final pngBytes = await _appState.capturedImageAsPng();
    if (pngBytes != null) {
      await _fileService.saveScreenshot(pngBytes);
    }
  }
  // Save dialog closed — now hide + clear.
  await _windowService.hidePreview();
  _appState.clear();
  _annotationState.clear();
  _clearDisplayCaches();
  unawaited(_windowService.stopEscMonitor());
  if (wasScrollResult) unawaited(_windowService.cleanupOverlay());
  unawaited(_windowService.startRectPolling());
}

Future<void> _handleDiscard() async {
  _escActionInProgress = false;
  final wasScrollResult = _appState.status == CaptureStatus.scrollResult;
  // Hide window BEFORE clearing state.
  await _windowService.hidePreview();
  _appState.clear();
  _annotationState.clear();
  // Non-blocking cleanup after window is gone.
  _clearDisplayCaches();
  unawaited(_windowService.stopEscMonitor());
  if (wasScrollResult) unawaited(_windowService.cleanupOverlay());
  unawaited(_windowService.startRectPolling());
}

// ---------------------------------------------------------------------------
// Pin to screen
// ---------------------------------------------------------------------------

/// Pin the selected region directly from the overlay (Snipaste-style).
/// Crops the selection, composites annotations, encodes to RGBA, and creates
/// a native floating sticker panel.
Future<void> _handleRegionPin(Rect logicalRect) async {
  _windowService.overlaySelectionActive = false;
  final decodedFullScreen = _appState.decodedFullScreen;
  final screenSize = _appState.screenSize;
  final screenOrigin = _appState.screenOrigin;
  if (decodedFullScreen == null || screenSize == null || screenOrigin == null) {
    _appState.clear();
    await _windowService.hidePreview();
    return;
  }

  final scaleX = decodedFullScreen.width / screenSize.width;
  final scaleY = decodedFullScreen.height / screenSize.height;
  final physicalRect = Rect.fromLTRB(
    logicalRect.left * scaleX,
    logicalRect.top * scaleY,
    logicalRect.right * scaleX,
    logicalRect.bottom * scaleY,
  );

  // Compute the CG-coordinate frame for the pinned panel BEFORE clearing
  // state. logicalRect is in screen-local coordinates; add screenOrigin to
  // get absolute CG coordinates (top-left origin).
  final cgPinFrame = Rect.fromLTWH(
    logicalRect.left + screenOrigin.dx,
    logicalRect.top + screenOrigin.dy,
    logicalRect.width,
    logicalRect.height,
  );

  // Capture annotation state before clearing.
  final annotations = _annotationState.annotations;

  // Detach the image so clear() won't dispose it — we need it for cropping.
  _appState.detachDecodedFullScreen();

  // Hide FIRST — user perceives instant dismiss.
  await _windowService.hidePreview();
  _appState.clear();
  _annotationState.clear();
  _clearDisplayCaches();
  unawaited(_windowService.stopEscMonitor());
  unawaited(_windowService.suspendOverlay());
  unawaited(_windowService.startRectPolling());

  // Crop + composite after the window is gone.
  var cropped = await _captureService.cropImage(
    decodedFullScreen,
    physicalRect,
  );
  if (cropped != null) {
    if (annotations.isNotEmpty) {
      final composited = await compositeAnnotations(cropped, annotations);
      cropped.dispose();
      cropped = composited;
    }

    // Encode to raw RGBA for the native panel.
    final byteData = await cropped.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    if (byteData != null) {
      _pinnedFlutterImage?.dispose();
      _pinnedFlutterImage = cropped;
      await _windowService.pinImage(
        bytes: byteData.buffer.asUint8List(),
        width: cropped.width,
        height: cropped.height,
        cgFrame: cgPinFrame,
      );
    } else {
      cropped.dispose();
    }
  }
  decodedFullScreen.dispose();
}

Future<void> _handlePin() async {
  _escActionInProgress = false;

  // Determine which image to pin:
  // 1. Preview is visible → use capturedImage (with annotations)
  // 2. After copy/save → use _lastCopiedImage (already composited)
  final image = _appState.capturedImage;
  final bool fromPreview = image != null;
  final ui.Image sourceImage;

  if (fromPreview) {
    // Detach immediately so a concurrent capture can't dispose the image
    // while we're compositing / encoding below.
    _appState.detachCapturedImage();
    sourceImage = image;
  } else if (_lastCopiedImage != null) {
    sourceImage = _lastCopiedImage!;
  } else {
    return;
  }

  // Capture annotations and window position before async work.
  final annotations = fromPreview
      ? _annotationState.annotations
      : const <Annotation>[];
  final Rect? previewFrame;
  if (fromPreview) {
    final windowPos = await windowManager.getPosition();
    final windowSize = await windowManager.getSize();
    previewFrame = Rect.fromLTWH(
      windowPos.dx,
      windowPos.dy,
      windowSize.width,
      windowSize.height,
    );
    // Hide Flutter window and return to idle.
    await _windowService.hidePreview();
    _appState.clear();
    _annotationState.clear();
    _clearDisplayCaches();
    unawaited(_windowService.stopEscMonitor());
    unawaited(_windowService.startRectPolling());
  } else {
    previewFrame = null;
  }

  // Composite annotations when pinning from preview.
  final ui.Image finalImage;
  if (fromPreview && annotations.isNotEmpty) {
    finalImage = await compositeAnnotations(sourceImage, annotations);
  } else {
    finalImage = sourceImage;
  }

  // Encode to raw RGBA for the native panel.
  final byteData = await finalImage.toByteData(
    format: ui.ImageByteFormat.rawStraightRgba,
  );
  if (byteData == null) {
    if (!identical(finalImage, sourceImage)) finalImage.dispose();
    sourceImage.dispose();
    if (!fromPreview) {
      _lastCopiedImage = null;
      _lastCopiedCgFrame = null;
    }
    return;
  }

  // Determine where to place the pin.
  final Rect cgFrame;
  if (fromPreview) {
    cgFrame = previewFrame!;
  } else {
    if (_lastCopiedCgFrame != null) {
      cgFrame = _lastCopiedCgFrame!;
    } else {
      // Center on cursor's screen.
      final screenInfo = await _windowService.getScreenInfo();
      final screenSize = screenInfo?.screenSize ?? const Size(1920, 1080);
      final screenOrigin = screenInfo?.screenOrigin ?? Offset.zero;
      final w = finalImage.width.toDouble();
      final h = finalImage.height.toDouble();
      cgFrame = Rect.fromLTWH(
        screenOrigin.dx + (screenSize.width - w) / 2,
        screenOrigin.dy + (screenSize.height - h) / 2,
        w,
        h,
      );
    }
  }

  // Keep a Dart-side reference for fast re-edit via Space.
  _pinnedFlutterImage?.dispose();
  if (fromPreview) {
    if (!identical(finalImage, sourceImage)) sourceImage.dispose();
    _pinnedFlutterImage = finalImage;
  } else {
    // Pinning from idle (after copy) — transfer _lastCopiedImage ownership.
    _pinnedFlutterImage = _lastCopiedImage;
    _lastCopiedImage = null;
    _lastCopiedCgFrame = null;
  }

  await _windowService.pinImage(
    bytes: byteData.buffer.asUint8List(),
    width: finalImage.width,
    height: finalImage.height,
    cgFrame: cgFrame,
  );
}

void _handleEditPinnedImage() {
  final pinnedImage = _pinnedFlutterImage;
  if (pinnedImage == null) return;
  _pinnedFlutterImage = null;

  unawaited(_handleEditPinnedImageAsync(pinnedImage));
}

Future<void> _handleEditPinnedImageAsync(ui.Image pinnedImage) async {
  // Get the pinned panel's CG frame BEFORE closing it so we can show the
  // Flutter preview at exactly the same position and size.
  final panelFrame = await _windowService.getPinnedPanelFrame();

  _annotationState.clear();

  // Show the preview at the pin's exact position and size so the image
  // doesn't jump or resize when entering annotation mode.
  // Keep it transparent until Flutter has rendered to avoid a flash.
  _appState.setCapturedImage(pinnedImage);
  if (panelFrame != null) {
    // panelFrame is in CG coordinates (absolute). Use showPreviewAtRect
    // which performs full window cleanup (restores opacity from any prior
    // suspendOverlay, resets styleMask, etc.).
    await _windowService.showPreviewAtRect(
      rect: panelFrame,
      opacity: 0.0,
      focus: false,
    );
  } else {
    // Fallback: center on screen if we couldn't get the panel frame.
    final screenInfo = await _windowService.getScreenInfo();
    final screenSize = screenInfo?.screenSize ?? const Size(1920, 1080);
    final screenOrigin = screenInfo?.screenOrigin ?? Offset.zero;
    await _windowService.showPreview(
      imageWidth: pinnedImage.width,
      imageHeight: pinnedImage.height,
      screenSize: screenSize,
      screenOrigin: screenOrigin,
      opacity: 0.0,
      focus: false,
    );
  }

  await WidgetsBinding.instance.endOfFrame;

  // Reveal the preview first, then close the pinned panel so there's no
  // visible gap between the two windows.
  await _windowService.revealPreviewWindow();
  await _windowService.closePinnedImage();
  _appState.nudge();
}

void _handlePinnedImageClosed() {
  _pinnedFlutterImage?.dispose();
  _pinnedFlutterImage = null;
}

// ---------------------------------------------------------------------------
// Scroll capture (manual)
// ---------------------------------------------------------------------------

Future<void> _handleScrollCapture() async {
  if (_appState.status == CaptureStatus.capturing ||
      _appState.status == CaptureStatus.scrollSelecting) {
    return;
  }
  if (_appState.status == CaptureStatus.scrollCapturing) {
    // Re-pressing hotkey finishes scroll capture
    if (!_escActionInProgress) {
      _escActionInProgress = true;
      unawaited(
        _handleScrollFinish().whenComplete(() {
          _escActionInProgress = false;
        }),
      );
    }
    return;
  }
  _escActionInProgress = false;
  _lastCopiedImage?.dispose();
  _lastCopiedImage = null;
  _lastCopiedCgFrame = null;
  await _windowService.stopEscMonitor();
  _annotationState.clear();
  _appState.setCapturing();
  _regionCaptureCancelled = false;
  await _windowService.hidePreview();
  _clearDisplayCaches();

  await _windowService.startEscMonitor();
  await _windowService.stopRectPolling();

  final capture = await _windowService.captureScreen();

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
      localRects = _globalRectsToLocal(capture.screenOrigin);
    } else {
      final windows = await _windowService.getWindowList();
      localRects = windows
          .map(
            (w) => w.rect.shift(
              Offset(-capture.screenOrigin.dx, -capture.screenOrigin.dy),
            ),
          )
          .toList();
    }
    _displayCaches[_displayKey(capture.screenOrigin)] = _DisplayCache(
      localRects: localRects,
    );

    final decodedImage = await _decodeRawPixels(capture);

    if (_regionCaptureCancelled) {
      _regionCaptureCancelled = false;
      decodedImage.dispose();
      _appState.clear();
      await _windowService.stopEscMonitor();
      await _windowService.startRectPolling();
      return;
    }

    _appState.setScrollSelecting(
      decodedImage: decodedImage,
      windowRects: localRects,
      screenSize: capture.screenSize,
      screenOrigin: capture.screenOrigin,
    );

    await _windowService.showFullScreenOverlay(
      screenOrigin: capture.screenOrigin,
    );

    if (_regionCaptureCancelled) {
      _regionCaptureCancelled = false;
      await _windowService.hidePreview();
      _appState.clear();
      await _windowService.cleanupOverlay();
      await _windowService.stopEscMonitor();
      await _windowService.startRectPolling();
      return;
    }

    await WidgetsBinding.instance.endOfFrame;
    await WidgetsBinding.instance.endOfFrame;

    if (_regionCaptureCancelled) {
      _regionCaptureCancelled = false;
      await _windowService.hidePreview();
      _appState.clear();
      await _windowService.cleanupOverlay();
      await _windowService.stopEscMonitor();
      await _windowService.startRectPolling();
      return;
    }

    await _windowService.revealOverlay();
    await _windowService.stopEscMonitor();
  } else {
    _appState.clear();
    await _windowService.stopEscMonitor();
    await _windowService.startRectPolling();
  }
}

Future<void> _handleScrollRegionSelected(Rect logicalRect) async {
  final screenSize = _appState.screenSize;
  final screenOrigin = _appState.screenOrigin;
  if (screenSize == null || screenOrigin == null) {
    _appState.clear();
    await _windowService.hidePreview();
    return;
  }

  // Convert logical selection rect to CG coordinates (absolute screen position).
  // NOTE: Do NOT call exitOverlay() here. The overlay and scroll capture mode
  // both use .borderless styleMask. Calling exitOverlayMode would restore a
  // titled styleMask and set everything opaque, then enterScrollCaptureMode
  // would set .borderless again — this double styleMask transition causes macOS
  // to recreate the Metal layer hierarchy, leaving the window opaque black.
  // Instead, enterScrollCaptureMode handles overlay cleanup (monitors, etc.)
  // directly.
  final cgRegion = Rect.fromLTWH(
    logicalRect.left + screenOrigin.dx,
    logicalRect.top + screenOrigin.dy,
    logicalRect.width,
    logicalRect.height,
  );

  // Transition to scroll capture mode BEFORE updating state so backgrounds
  // are cleared before the transparent widget renders (avoids black flash).
  await _windowService.enterScrollCaptureMode();
  _appState.setScrollCapturing(captureRegion: cgRegion);
  await _windowService.startEscMonitor();

  // Wire up callbacks and start manual capture loop
  _scrollCaptureService.onProgress = _appState.updateScrollFrameCount;
  _scrollCaptureService.onPreviewUpdated = _appState.updateScrollPreview;
  _scrollCaptureService.startManualCapture(cgRegion, _windowService);
}

Future<void> _handleScrollFinish() async {
  await _windowService.hideScrollStopButton();
  await _windowService.stopEscMonitor();

  final result = await _scrollCaptureService.stopCapture();

  if (result != null) {
    // Defensive guard: if a disposed/invalid image slips through due to any
    // unforeseen async race, fail gracefully to idle instead of crashing.
    int imageWidth;
    int imageHeight;
    try {
      imageWidth = result.width;
      imageHeight = result.height;
    } catch (_) {
      _appState.clear();
      await _windowService.hidePreview();
      // Defer overlay cleanup to the next show transition to avoid close flash.
      await _windowService.startRectPolling();
      return;
    }
    if (imageWidth <= 0 || imageHeight <= 0) {
      result.dispose();
      _appState.clear();
      await _windowService.hidePreview();
      // Defer overlay cleanup to the next show transition to avoid close flash.
      await _windowService.startRectPolling();
      return;
    }

    // Stay in fullscreen overlay — just re-enable mouse interaction.
    _appState.setScrollResult(result);
    await _windowService.exitScrollCaptureMode();
    _appState.nudge();
    // No native Esc monitor — ScrollResultScreen handles Escape via
    // HardwareKeyboard (supports shapes mode unwinding).
  } else {
    _appState.clear();
    await _windowService.hidePreview();
    // Defer overlay cleanup to the next show transition to avoid close flash.
    await _windowService.startRectPolling();
  }
}

/// Called by the "Done" button in the live preview panel (via native NSPanel).
void _handleScrollCaptureDone() {
  if (_appState.status != CaptureStatus.scrollCapturing) return;
  if (_escActionInProgress) return;
  _escActionInProgress = true;
  unawaited(
    _handleScrollFinish().whenComplete(() {
      _escActionInProgress = false;
    }),
  );
}

/// Called by ScrollCapturePreview when its "Done" button position changes.
/// Forwards the CG rect to the native side so it can place a clickable panel.
void _handleScrollStopButtonRect(Rect cgRect) {
  unawaited(_windowService.showScrollStopButton(cgRect));
}

Future<void> _handleScrollCancel() async {
  await _windowService.hideScrollStopButton();
  await _windowService.stopEscMonitor();
  _scrollCaptureService.requestCancel();
  _appState.clear();
  await _windowService.hidePreview();
  // Defer overlay cleanup to the next show transition to avoid close flash.
  await _windowService.startRectPolling();
}

Future<void> _handleQuit() async {
  // Clean up pinned/cached images.
  _pinnedFlutterImage?.dispose();
  _pinnedFlutterImage = null;
  _lastCopiedImage?.dispose();
  _lastCopiedImage = null;
  _lastCopiedCgFrame = null;
  unawaited(_windowService.closePinnedImage());

  await _windowService.stopEscMonitor();
  await _windowService.stopRectPolling();
  await _hotkeyService.unregisterAll();
  await _trayService.destroy();
  await windowManager.destroy();
  exit(0);
}
