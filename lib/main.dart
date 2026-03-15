import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
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
import 'services/settings_service.dart';
import 'services/tray_service.dart';
import 'services/window_service.dart';
import 'state/annotation_state.dart';
import 'state/app_state.dart';
import 'state/settings_state.dart';
import 'utils/annotation_compositor.dart';
import 'utils/url_detection.dart';

bool _displayChangeInProgress = false;
bool _displayChangePending = false;
bool _regionCaptureCancelled = false;
bool _escActionInProgress = false;

/// Keeps one cloned `ui.Image` per pinned native panel for fast re-edit via
/// Space (avoids round-tripping image bytes through the platform channel).
final Map<int, ui.Image> _pinnedFlutterImages = {};

/// Last captured/copied image kept alive for deferred pinning.
/// Allows "capture → copy → pin" workflow: copy clears the preview but this
/// reference survives so a subsequent Pin command can still pin the image.
ui.Image? _lastCopiedImage;

/// CG-coordinate frame of the last copied image (for pin placement).
Rect? _lastCopiedCgFrame;

/// Exact PNG bytes written to the clipboard for deferred idle pin validation.
Uint8List? _lastCopiedClipboardPngBytes;

/// Pre-cached window rects from background polling.
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

void _disposePinnedPanelImage(int panelId) {
  _pinnedFlutterImages.remove(panelId)?.dispose();
}

void _disposeAllPinnedPanelImages() {
  for (final image in _pinnedFlutterImages.values) {
    image.dispose();
  }
  _pinnedFlutterImages.clear();
}

void _clearLastCopiedPinCache() {
  _lastCopiedImage?.dispose();
  _lastCopiedImage = null;
  _lastCopiedCgFrame = null;
  _lastCopiedClipboardPngBytes = null;
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
late final SettingsService _settingsService;
late final SettingsState _settingsState;
late final WindowService _windowService;
final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
bool _ocrInProgress = false;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  _appState = AppState();
  _annotationState = AnnotationState();
  _captureService = CaptureService();
  _clipboardService = ClipboardService();
  _fileService = FileService();
  _hotkeyService = HotkeyService();
  _scrollCaptureService = ScrollCaptureService();
  _settingsService = SettingsService();
  _trayService = TrayService();
  _windowService = WindowService();

  await _windowService.ensureInitialized();

  final initialShortcuts = await _settingsService.loadShortcutBindings();
  final initialOcrPreviewEnabled = await _settingsService
      .loadOcrPreviewEnabled();
  final initialOcrOpenUrlPromptEnabled = await _settingsService
      .loadOcrOpenUrlPromptEnabled();
  _settingsState = SettingsState(
    initialShortcuts: initialShortcuts,
    initialOcrPreviewEnabled: initialOcrPreviewEnabled,
    initialOcrOpenUrlPromptEnabled: initialOcrOpenUrlPromptEnabled,
    settingsService: _settingsService,
    windowService: _windowService,
    hotkeyService: _hotkeyService,
    trayService: _trayService,
  );

  runApp(
    ASnapApp(
      appState: _appState,
      annotationState: _annotationState,
      settingsState: _settingsState,
      windowService: _windowService,
      navigatorKey: _navigatorKey,
      onCopy: _handleCopy,
      onSave: _handleSave,
      onPin: _handlePin,
      onDiscard: _handleDiscard,
      onOcr: _handleOcr,
      onCopyText: _handleCopyText,
      onRegionSelected: _handleRegionSelected,
      onRegionOcr: _handleRegionOcr,
      onRegionCopy: _handleRegionCopy,
      onRegionSave: _handleRegionSave,
      onRegionPin: _handleRegionPin,
      onScrollRegionSelected: _handleScrollRegionSelected,
      onRegionCancel: _handleRegionCancel,
      onHitTest: _handleHitTest,
      onScrollCaptureDone: _handleScrollCaptureDone,
      onScrollStopButtonRect: _handleScrollStopButtonRect,
      onCloseSettings: _handleCloseSettings,
      onSuspendHotkeys: _handleSuspendHotkeys,
      onResumeHotkeys: _handleResumeHotkeys,
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

    if (_appState.workflow is ScrollCapturingWorkflow) {
      _escActionInProgress = true;
      unawaited(
        _handleScrollCancel().whenComplete(() {
          _escActionInProgress = false;
        }),
      );
      return;
    }

    if (_appState.workflow is RegionSelectionWorkflow) {
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

  await _trayService.init(shortcuts: _settingsState.shortcuts);
  _trayService.onCaptureFullScreen = _handleFullScreenCapture;
  _trayService.onCaptureRegion = _handleRegionCapture;
  _trayService.onCaptureScroll = _handleScrollCapture;
  _trayService.onPin = _handlePin;
  _trayService.onOpenSettings = _handleOpenSettings;
  _trayService.onQuit = _handleQuit;

  await _hotkeyService.initialize(
    bindings: _settingsState.shortcuts,
    onFullScreen: _handleFullScreenCapture,
    onRegion: _handleRegionCapture,
    onScrollCapture: _handleScrollCapture,
    onPin: _handlePin,
    onOcr: _handleOcrShortcut,
  );

  // Start background rect polling — keeps top-level window rects warm
  // so captures are instant; element hit-testing stays on-demand.
  await _windowService.startRectPolling();
}

void _handleEscPressed() {
  switch (_appState.workflow) {
    case PreparingCaptureWorkflow():
      // During capture setup, Esc should abort the flow immediately.
      _regionCaptureCancelled = true;
      return;
    case RegionSelectionWorkflow():
      // Fallback: region overlay normally handles Esc in Flutter.
      if (_escActionInProgress) return;
      _escActionInProgress = true;
      unawaited(
        _handleRegionCancel().whenComplete(() {
          _escActionInProgress = false;
        }),
      );
      return;
    case PreviewWorkflow():
    case ScrollResultWorkflow():
      if (_escActionInProgress) return;
      _escActionInProgress = true;
      unawaited(
        _handleDiscard().whenComplete(() {
          _escActionInProgress = false;
        }),
      );
      return;
    case ScrollCapturingWorkflow():
      // Esc during scroll capture = cancel (discard frames)
      if (_escActionInProgress) return;
      _escActionInProgress = true;
      unawaited(
        _handleScrollCancel().whenComplete(() {
          _escActionInProgress = false;
        }),
      );
      return;
    case SettingsWorkflow():
      if (_escActionInProgress) return;
      _escActionInProgress = true;
      unawaited(
        _handleCloseSettings().whenComplete(() {
          _escActionInProgress = false;
        }),
      );
      return;
    case IdleWorkflow():
      return;
  }
}

Future<void> _handleOpenSettings() async {
  if (_appState.workflow is PreparingCaptureWorkflow) {
    return;
  }

  _escActionInProgress = false;
  await _windowService.stopEscMonitor();
  await _windowService.hideScrollStopButton();

  switch (_appState.workflow) {
    case RegionSelectionWorkflow():
      await _handleRegionCancel();
      break;
    case ScrollCapturingWorkflow():
      await _handleScrollCancel();
      break;
    case PreviewWorkflow():
    case ScrollResultWorkflow():
      await _handleDiscard();
      break;
    case SettingsWorkflow():
      await _windowService.showSettingsWindow();
      _appState.nudge();
      unawaited(_settingsState.refreshLaunchAtLogin());
      return;
    case IdleWorkflow():
      break;
    case PreparingCaptureWorkflow():
      return;
  }

  _annotationState.clear();
  _clearDisplayCaches();
  await _windowService.hideToolbarPanel();
  _appState.setSettings();
  await _windowService.showSettingsWindow();
  _appState.nudge();
  unawaited(_settingsState.refreshLaunchAtLogin());
}

Future<void> _handleCloseSettings() async {
  _escActionInProgress = false;
  await _windowService.stopEscMonitor();
  await _windowService.hideToolbarPanel();
  _appState.clear();
  _annotationState.clear();
  _clearDisplayCaches();
  await _windowService.hidePreview();
}

Future<void> _handleSuspendHotkeys() async {
  await _hotkeyService.suspend();
}

Future<void> _handleResumeHotkeys() async {
  await _hotkeyService.resume();
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

Future<ui.Image> _decodeStraightRgbaImage(
  Uint8List rgbaBytes,
  int width,
  int height,
) {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    rgbaBytes,
    width,
    height,
    ui.PixelFormat.rgba8888,
    completer.complete,
    rowBytes: width * 4,
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

Future<bool> _lastCopiedImageStillMatchesClipboard() async {
  final expectedPngBytes = _lastCopiedClipboardPngBytes;
  if (_lastCopiedImage == null || expectedPngBytes == null) {
    return false;
  }

  final matches = await _clipboardService.containsMatchingImage(
    expectedPngBytes,
  );
  if (!matches) {
    _clearLastCopiedPinCache();
  }
  return matches;
}

Future<int?> _pinNativeImageFromRgbaBytes({
  required Uint8List rgbaBytes,
  required int width,
  required int height,
  required Rect cgFrame,
}) async {
  final pinnedImage = await _decodeStraightRgbaImage(rgbaBytes, width, height);
  try {
    final panelId = await _windowService.pinImage(
      bytes: rgbaBytes,
      width: width,
      height: height,
      cgFrame: cgFrame,
    );
    if (panelId == null) {
      pinnedImage.dispose();
      return null;
    }
    _disposePinnedPanelImage(panelId);
    _pinnedFlutterImages[panelId] = pinnedImage;
    return panelId;
  } catch (_) {
    pinnedImage.dispose();
    rethrow;
  }
}

/// Real-time AX hit-test: convert local overlay coordinates to global CG
/// coordinates, query the deepest accessible element, and return the result
/// back in local coordinates.
Future<Rect?> _handleHitTest(Offset localPoint) async {
  final selection = _appState.regionSelectionWorkflow;
  if (selection == null) return null;
  final screenOrigin = selection.screenOrigin;

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
  if (_appState.workflow is PreparingCaptureWorkflow) return;
  _escActionInProgress = false;
  _clearLastCopiedPinCache();
  await _windowService.stopEscMonitor();
  _annotationState.clear();
  _appState.setPreparingCapture(kind: CaptureKind.fullScreen);
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

Future<void> _startSelectionCapture({
  required CaptureKind kind,
  required SelectionMode selectionMode,
}) async {
  _escActionInProgress = false;
  _clearLastCopiedPinCache();
  await _windowService.stopEscMonitor();
  // Allow re-entry from selecting state (display-change re-trigger).
  _annotationState.clear();
  _appState.setPreparingCapture(kind: kind);
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

    switch (selectionMode) {
      case SelectionMode.region:
        _appState.setSelecting(
          decodedImage: decodedImage,
          windowRects: localRects,
          screenSize: capture.screenSize,
          screenOrigin: capture.screenOrigin,
        );
      case SelectionMode.scroll:
        _appState.setScrollSelecting(
          decodedImage: decodedImage,
          windowRects: localRects,
          screenSize: capture.screenSize,
          screenOrigin: capture.screenOrigin,
        );
      case SelectionMode.ocr:
        _appState.setOcrSelecting(
          decodedImage: decodedImage,
          windowRects: localRects,
          screenSize: capture.screenSize,
          screenOrigin: capture.screenOrigin,
        );
    }

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

Future<void> _handleRegionCapture() async {
  if (_appState.workflow is PreparingCaptureWorkflow) return;
  await _startSelectionCapture(
    kind: CaptureKind.region,
    selectionMode: SelectionMode.region,
  );
}

Future<void> _handleOcrShortcut() async {
  if (_appState.workflow is PreparingCaptureWorkflow) return;
  await _startSelectionCapture(
    kind: CaptureKind.ocr,
    selectionMode: SelectionMode.ocr,
  );
}

/// Called when the cursor moves to a different display during overlay mode.
/// Uses fast suspend/resume path (no window property restore/reconfigure)
/// and pre-cached global rects for instant display switching.
Future<void> _handleDisplayChanged() async {
  final selection = _appState.regionSelectionWorkflow;
  if (selection == null) return;

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
    if (selection.isScrollSelection) {
      _appState.setScrollSelecting(
        decodedImage: decodedImage,
        windowRects: localRects,
        screenSize: capture.screenSize,
        screenOrigin: capture.screenOrigin,
      );
    } else if (selection.isOcrSelection) {
      _appState.setOcrSelecting(
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
  final selection = _appState.regionSelectionWorkflow;
  if (selection == null) {
    _appState.clear();
    await _windowService.hidePreview();
    return;
  }
  final decodedFullScreen = selection.decodedImage;
  final screenSize = selection.screenSize;
  final screenOrigin = selection.screenOrigin;

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
      await _windowService.showPreviewInPlace(
        selectionRect: logicalRect,
        screenSize: screenSize,
        screenOrigin: screenOrigin,
      );
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
  final selection = _appState.regionSelectionWorkflow;
  if (selection == null) {
    _appState.clear();
    await _windowService.hidePreview();
    return;
  }
  final decodedFullScreen = selection.decodedImage;
  final screenSize = selection.screenSize;
  final screenOrigin = selection.screenOrigin;

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
    final pngBytes = byteData?.buffer.asUint8List();
    final copied =
        pngBytes != null && await _clipboardService.copyImage(pngBytes);
    _clearLastCopiedPinCache();
    if (copied) {
      _lastCopiedImage = cropped;
      _lastCopiedCgFrame = cgPinFrame;
      _lastCopiedClipboardPngBytes = Uint8List.fromList(pngBytes);
    } else {
      cropped.dispose();
    }
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
  final selection = _appState.regionSelectionWorkflow;
  if (selection == null) {
    _appState.clear();
    await _windowService.hidePreview();
    return;
  }
  final decodedFullScreen = selection.decodedImage;
  final screenSize = selection.screenSize;

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

Future<void> _handleRegionOcr(Rect logicalRect) async {
  if (_ocrInProgress) return;
  _windowService.overlaySelectionActive = false;
  final selection = _appState.regionSelectionWorkflow;
  if (selection == null) {
    _appState.clear();
    await _windowService.hidePreview();
    return;
  }
  final decodedFullScreen = selection.decodedImage;
  final screenSize = selection.screenSize;

  final scaleX = decodedFullScreen.width / screenSize.width;
  final scaleY = decodedFullScreen.height / screenSize.height;
  final physicalRect = Rect.fromLTRB(
    logicalRect.left * scaleX,
    logicalRect.top * scaleY,
    logicalRect.right * scaleX,
    logicalRect.bottom * scaleY,
  );

  final showPreview =
      _settingsState.ocrPreviewEnabled && !selection.isOcrSelection;
  final keepWindowVisible =
      showPreview || _settingsState.ocrOpenUrlPromptEnabled;
  var windowHidden = false;

  _ocrInProgress = true;
  _appState.detachDecodedFullScreen();
  try {
    await _windowService.hideToolbarPanel();
    if (!keepWindowVisible) {
      // Hide FIRST — user perceives instant dismiss when no UI is needed.
      await _windowService.hidePreview();
      _appState.clear();
      _annotationState.clear();
      _clearDisplayCaches();
      unawaited(_windowService.stopEscMonitor());
      unawaited(_windowService.suspendOverlay());
      unawaited(_windowService.startRectPolling());
      windowHidden = true;
    }

    final cropped = await _captureService.cropImage(
      decodedFullScreen,
      physicalRect,
    );
    if (cropped == null) return;

    final byteData = await cropped.toByteData(format: ui.ImageByteFormat.png);
    final pngBytes = byteData?.buffer.asUint8List();
    if (pngBytes != null) {
      final normalized = await _recognizeTextFromPng(pngBytes);
      if (normalized != null) {
        await _applyOcrResult(normalized, showPreview: showPreview);
      }
    }
    cropped.dispose();
  } finally {
    _ocrInProgress = false;
    if (!windowHidden) {
      await _windowService.hidePreview();
      _appState.clear();
      _annotationState.clear();
      _clearDisplayCaches();
      unawaited(_windowService.stopEscMonitor());
      unawaited(_windowService.suspendOverlay());
      unawaited(_windowService.startRectPolling());
    }
    decodedFullScreen.dispose();
  }
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
  final wasScrollResult = _appState.workflow is ScrollResultWorkflow;
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
    final pngBytes = byteData?.buffer.asUint8List();
    final copied =
        pngBytes != null && await _clipboardService.copyImage(pngBytes);

    _clearLastCopiedPinCache();
    if (copied) {
      if (!identical(finalImage, image)) {
        image.dispose();
        _lastCopiedImage = finalImage;
      } else {
        _lastCopiedImage = image;
      }
      _lastCopiedCgFrame = copyCgFrame;
      _lastCopiedClipboardPngBytes = Uint8List.fromList(pngBytes);
    } else if (!identical(finalImage, image)) {
      finalImage.dispose();
      image.dispose();
    } else {
      image.dispose();
    }
  } else {
    _clearLastCopiedPinCache();
  }
  _clearDisplayCaches();
  unawaited(_windowService.stopEscMonitor());
  if (wasScrollResult) unawaited(_windowService.cleanupOverlay());
  unawaited(_windowService.startRectPolling());
}

Future<void> _handleCopyText(String text) async {
  await _clipboardService.copyText(text);
}

Future<void> _handleSave() async {
  _escActionInProgress = false;
  final wasScrollResult = _appState.workflow is ScrollResultWorkflow;
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
  final wasScrollResult = _appState.workflow is ScrollResultWorkflow;
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

Future<String?> _recognizeTextFromPng(Uint8List pngBytes) async {
  final text = await _windowService.recognizeText(pngBytes: pngBytes);
  if (text == null) return null;
  return text.trim();
}

Future<void> _openUrlInBrowser(String url) async {
  await _windowService.openUrl(url);
}

Future<void> _showOpenUrlPrompt(String url) async {
  final context = _navigatorKey.currentContext;
  if (context == null) return;

  await showDialog<void>(
    context: context,
    builder: (context) {
      return AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title: const Text('Open URL?', style: TextStyle(color: Colors.white)),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: SelectableText(
            url,
            style: const TextStyle(color: Colors.white70, height: 1.4),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop();
              unawaited(_openUrlInBrowser(url));
            },
            child: const Text('Open'),
          ),
        ],
      );
    },
  );
}

Future<void> _applyOcrResult(String text, {required bool showPreview}) async {
  if (text.isNotEmpty) {
    await _clipboardService.copyText(text);
  }
  final url = _settingsState.ocrOpenUrlPromptEnabled
      ? extractFirstUrl(text)
      : null;
  if (showPreview) {
    await _showOcrPreviewDialog(text, url: url);
  } else if (url != null) {
    await _showOpenUrlPrompt(url);
  }
}

Future<void> _handleOcr() async {
  if (_ocrInProgress) return;
  final image = _appState.capturedImage;
  if (image == null) return;

  _ocrInProgress = true;
  try {
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    final pngBytes = byteData?.buffer.asUint8List();
    if (pngBytes == null) return;

    final normalized = await _recognizeTextFromPng(pngBytes);
    if (normalized == null) return;
    await _applyOcrResult(
      normalized,
      showPreview: _settingsState.ocrPreviewEnabled,
    );
  } finally {
    _ocrInProgress = false;
  }
}

Future<void> _showOcrPreviewDialog(String text, {String? url}) async {
  final context = _navigatorKey.currentContext;
  if (context == null) return;

  final hasText = text.trim().isNotEmpty;
  await showDialog<void>(
    context: context,
    builder: (context) {
      return AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title: const Text('OCR Result', style: TextStyle(color: Colors.white)),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520, maxHeight: 280),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                SelectableText(
                  hasText ? text : 'No text recognized.',
                  style: TextStyle(
                    color: hasText ? Colors.white70 : Colors.white54,
                    height: 1.4,
                  ),
                ),
                if (url != null) ...[
                  const SizedBox(height: 14),
                  const Text(
                    'Detected URL',
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.2,
                    ),
                  ),
                  const SizedBox(height: 6),
                  SelectableText(
                    url,
                    style: const TextStyle(color: Colors.white70, height: 1.4),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          if (hasText)
            TextButton(
              onPressed: () {
                unawaited(_clipboardService.copyText(text));
              },
              child: const Text('Copy'),
            ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
          if (url != null)
            FilledButton(
              onPressed: () {
                Navigator.of(context).pop();
                unawaited(_openUrlInBrowser(url));
              },
              child: const Text('Open URL'),
            ),
        ],
      );
    },
  );
}

// ---------------------------------------------------------------------------
// Pin to screen
// ---------------------------------------------------------------------------

/// Pin the selected region directly from the overlay (Snipaste-style).
/// Crops the selection, composites annotations, encodes to RGBA, and creates
/// a native floating sticker panel.
Future<void> _handleRegionPin(Rect logicalRect) async {
  _windowService.overlaySelectionActive = false;
  final selection = _appState.regionSelectionWorkflow;
  if (selection == null) {
    _appState.clear();
    await _windowService.hidePreview();
    return;
  }
  final decodedFullScreen = selection.decodedImage;
  final screenSize = selection.screenSize;
  final screenOrigin = selection.screenOrigin;

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
      final rgbaBytes = Uint8List.fromList(byteData.buffer.asUint8List());
      await _pinNativeImageFromRgbaBytes(
        rgbaBytes: rgbaBytes,
        width: cropped.width,
        height: cropped.height,
        cgFrame: cgPinFrame,
      );
    }
    cropped.dispose();
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
  } else if (await _lastCopiedImageStillMatchesClipboard()) {
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
    if (fromPreview) {
      finalImage.dispose();
      if (!identical(finalImage, sourceImage)) {
        sourceImage.dispose();
      }
    } else {
      _clearLastCopiedPinCache();
    }
    return;
  }
  final rgbaBytes = Uint8List.fromList(byteData.buffer.asUint8List());

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

  try {
    await _pinNativeImageFromRgbaBytes(
      rgbaBytes: rgbaBytes,
      width: finalImage.width,
      height: finalImage.height,
      cgFrame: cgFrame,
    );
  } finally {
    if (fromPreview) {
      finalImage.dispose();
      if (!identical(finalImage, sourceImage)) {
        sourceImage.dispose();
      }
    }
  }
}

void _handleEditPinnedImage(int panelId) {
  final pinnedImage = _pinnedFlutterImages.remove(panelId);
  if (pinnedImage == null) return;

  unawaited(_handleEditPinnedImageAsync(panelId, pinnedImage));
}

Future<void> _handleEditPinnedImageAsync(
  int panelId,
  ui.Image pinnedImage,
) async {
  // Get the pinned panel's CG frame BEFORE closing it so we can show the
  // Flutter preview at exactly the same position and size.
  final panelFrame = await _windowService.getPinnedPanelFrame(panelId: panelId);

  _annotationState.clear();

  // Clear any previously shown toolbar state before rebuilding the preview.
  // This avoids a stale panel briefly appearing at an old location.
  await _windowService.hideToolbarPanel();

  // Show the preview at the pin's exact position and size so the image
  // doesn't jump or resize when entering annotation mode.
  // Keep it transparent until Flutter has rendered to avoid a flash.
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

  // Set image/state only after the native preview window has its final frame.
  // Otherwise PreviewScreen can compute toolbar geometry from stale window
  // constraints during the transition.
  _appState.setCapturedImage(pinnedImage);

  await WidgetsBinding.instance.endOfFrame;

  // Reveal the preview first, then close the pinned panel so there's no
  // visible gap between the two windows.
  await _windowService.revealPreviewWindow();
  await _windowService.closePinnedImage(panelId: panelId);
  _appState.nudge();
}

void _handlePinnedImageClosed(int panelId) {
  _disposePinnedPanelImage(panelId);
}

// ---------------------------------------------------------------------------
// Scroll capture (manual)
// ---------------------------------------------------------------------------

Future<void> _handleScrollCapture() async {
  if (_appState.workflow is PreparingCaptureWorkflow ||
      switch (_appState.workflow) {
        RegionSelectionWorkflow(selectionMode: SelectionMode.scroll) => true,
        _ => false,
      }) {
    return;
  }
  if (_appState.workflow is ScrollCapturingWorkflow) {
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
  await _startSelectionCapture(
    kind: CaptureKind.scroll,
    selectionMode: SelectionMode.scroll,
  );
}

Future<void> _handleScrollRegionSelected(Rect logicalRect) async {
  final selection = _appState.regionSelectionWorkflow;
  if (selection == null) {
    _appState.clear();
    await _windowService.hidePreview();
    return;
  }
  final screenOrigin = selection.screenOrigin;

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
  if (_appState.workflow is! ScrollCapturingWorkflow) return;
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
  _disposeAllPinnedPanelImages();
  _clearLastCopiedPinCache();
  unawaited(_windowService.closePinnedImage());

  await _windowService.stopEscMonitor();
  await _windowService.stopRectPolling();
  await _hotkeyService.unregisterAll();
  await _trayService.destroy();
  await windowManager.destroy();
  exit(0);
}
