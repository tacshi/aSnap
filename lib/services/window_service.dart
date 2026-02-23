import 'dart:async';

import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

/// A visible on-screen window detected via CGWindowListCopyWindowInfo.
class DetectedWindow {
  final Rect rect;
  const DetectedWindow({required this.rect});
}

/// Raw BGRA pixel data + the captured display's logical size and CG origin.
class ScreenCapture {
  /// Raw BGRA pixel bytes (no PNG encoding).
  final Uint8List bytes;

  /// Physical pixel dimensions of the captured image.
  final int pixelWidth;
  final int pixelHeight;

  /// Bytes per row (may include padding beyond pixelWidth × 4).
  final int bytesPerRow;

  /// Logical (point) size of the captured display.
  final Size screenSize;

  /// Top-left origin of this display in global CG coordinates.
  final Offset screenOrigin;

  const ScreenCapture({
    required this.bytes,
    required this.pixelWidth,
    required this.pixelHeight,
    required this.bytesPerRow,
    required this.screenSize,
    required this.screenOrigin,
  });
}

class WindowService {
  static const _minPreviewSize = Size(400, 300);
  static const _channel = MethodChannel('com.asnap/window');

  /// Called when the native side detects a Space switch during overlay mode.
  VoidCallback? onOverlayCancelled;

  /// Called when the cursor moves to a different display during overlay mode.
  VoidCallback? onOverlayDisplayChanged;

  /// Called when the native Esc key monitor detects Escape during capture setup.
  VoidCallback? onEscPressed;

  /// Called when the native scroll-stop button panel is clicked.
  VoidCallback? onScrollCaptureDone;

  /// Called when background rect polling delivers updated window/element rects.
  /// Rects are in global CG coordinates (top-left origin).
  void Function(List<DetectedWindow> windows)? onRectsUpdated;

  Future<void> ensureInitialized() async {
    await windowManager.ensureInitialized();

    // Listen for native → Dart callbacks
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onOverlayCancelled') {
        onOverlayCancelled?.call();
      } else if (call.method == 'onOverlayDisplayChanged') {
        onOverlayDisplayChanged?.call();
      } else if (call.method == 'onEscPressed') {
        onEscPressed?.call();
      } else if (call.method == 'onScrollCaptureDone') {
        onScrollCaptureDone?.call();
      } else if (call.method == 'onRectsUpdated') {
        final rawList = call.arguments as List<dynamic>?;
        if (rawList != null) {
          final windows = rawList.map((entry) {
            final map = Map<String, dynamic>.from(entry as Map);
            return DetectedWindow(
              rect: Rect.fromLTWH(
                (map['x'] as num).toDouble(),
                (map['y'] as num).toDouble(),
                (map['width'] as num).toDouble(),
                (map['height'] as num).toDouble(),
              ),
            );
          }).toList();
          onRectsUpdated?.call(windows);
        }
      }
    });
  }

  Future<void> hideOnReady() async {
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(200, 200),
        center: true,
        skipTaskbar: true,
        titleBarStyle: TitleBarStyle.hidden,
      ),
      () async {
        await windowManager.hide();
        await windowManager.setSkipTaskbar(true);
        await windowManager.setPreventClose(true);
      },
    );
  }

  Future<void> showPreview({
    required int imageWidth,
    required int imageHeight,
    required Size screenSize,
    required Offset screenOrigin,
  }) async {
    if (imageWidth <= 0 || imageHeight <= 0) return;

    // Ensure hidden before cleanup to avoid any transient redraw while
    // transitioning from full-screen overlay to preview.
    await windowManager.hide();
    // Clean overlay state first in case we're coming from region selection.
    // Avoids styleMask restoration while hidden, which can flash on macOS.
    await _channel.invokeMethod('cleanupOverlayMode');

    final maxW = screenSize.width * 0.8;
    final maxH = screenSize.height * 0.8;

    // Size window to image aspect ratio (toolbar floats over image)
    final imageAspect = imageWidth / imageHeight;
    var winW = imageWidth.toDouble();
    var winH = imageHeight.toDouble();

    if (winW > maxW) {
      winW = maxW;
      winH = winW / imageAspect;
    }
    if (winH > maxH) {
      winH = maxH;
      winW = winH * imageAspect;
    }

    winW = winW.clamp(_minPreviewSize.width, maxW);
    winH = winH.clamp(_minPreviewSize.height, maxH);

    final previewSize = Size(winW, winH);

    await windowManager.setMinimumSize(const Size(0, 0));
    await windowManager.setMaximumSize(
      Size(screenSize.width, screenSize.height),
    );
    await windowManager.setTitleBarStyle(
      TitleBarStyle.hidden,
      windowButtonVisibility: false,
    );
    await windowManager.setSize(previewSize);
    await windowManager.setMinimumSize(previewSize);
    await windowManager.setMaximumSize(previewSize);
    await windowManager.setAlwaysOnTop(true);
    await windowManager.setSkipTaskbar(true);
    await windowManager.setHasShadow(true);

    // Center on the cursor's display
    final x = screenOrigin.dx + (screenSize.width - previewSize.width) / 2;
    final y = screenOrigin.dy + (screenSize.height - previewSize.height) / 2;
    await windowManager.setPosition(Offset(x, y));

    // Restore opacity right before show — cleanupOverlayState leaves alpha=0
    // to prevent flash during styleMask restoration.
    await windowManager.setOpacity(1.0);
    await windowManager.show();
    await _focusAndActivateWindow();

    // One more pass right after show to avoid focus races during
    // overlay -> preview transitions.
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await _focusAndActivateWindow();
  }

  /// Show the overlay window covering the entire screen including the menu bar.
  /// Uses a native platform channel to set a borderless window above everything.
  ///
  /// When [screenOrigin] is provided (CG coordinates), the native side targets
  /// that exact display instead of re-reading the mouse position.  This avoids
  /// a race condition where the cursor may have moved between captureScreen and
  /// enterOverlayMode.
  Future<void> showFullScreenOverlay({Offset? screenOrigin}) async {
    final args = screenOrigin != null
        ? {'screenOriginX': screenOrigin.dx, 'screenOriginY': screenOrigin.dy}
        : null;
    await _channel.invokeMethod('enterOverlayMode', args);
  }

  /// Fully exit overlay mode: restore window style, level, observers.
  Future<void> exitOverlay() async {
    await _channel.invokeMethod('exitOverlayMode');
  }

  /// Clean overlay-only state without restoring styleMask.
  /// Use this for fast transitions where restoring style can flash.
  Future<void> cleanupOverlay() async {
    await _channel.invokeMethod('cleanupOverlayMode');
  }

  /// Make overlay invisible (alpha=0) for display switching.
  /// The window stays in the compositor so Flutter keeps rendering to its
  /// backing store — no surface release/reacquire flash.
  Future<void> suspendOverlay() async {
    await _channel.invokeMethod('suspendOverlay');
  }

  /// Move the invisible overlay to a new display (setFrame only).
  /// Window stays alpha=0 so Flutter can render the new content at the
  /// correct display size before [revealOverlay] makes it visible.
  Future<void> repositionOverlay({required Offset screenOrigin}) async {
    await _channel.invokeMethod('repositionOverlay', {
      'screenOriginX': screenOrigin.dx,
      'screenOriginY': screenOrigin.dy,
    });
  }

  /// Reveal the overlay (alpha=1) after Flutter has rendered the new content.
  /// Also re-activates the window and reinstalls display-change monitors.
  Future<void> revealOverlay() async {
    await _channel.invokeMethod('revealOverlay');
  }

  /// Shrink the overlay window in-place to the selection rect for preview.
  /// Stays borderless (no corner radius) and floating above other windows.
  /// Enforces a minimum size so the toolbar always fits, expanding outward
  /// from the selection center if needed.
  Future<void> showPreviewInPlace({required Rect selectionRect}) async {
    // Enforce minimum so the toolbar never overflows
    final w = selectionRect.width.clamp(_minPreviewSize.width, double.infinity);
    final h = selectionRect.height.clamp(
      _minPreviewSize.height,
      double.infinity,
    );
    final rect = Rect.fromCenter(
      center: selectionRect.center,
      width: w,
      height: h,
    );

    await _channel.invokeMethod('resizeToRect', {
      'x': rect.left,
      'y': rect.top,
      'width': rect.width,
      'height': rect.height,
    });
  }

  /// Capture the screen.
  ///
  /// When [allDisplays] is false (default), captures only the display under
  /// the mouse cursor (used for ⌘⇧1 fullscreen capture).  When true, captures
  /// all connected displays as a single composite (used for ⌘⇧2 region
  /// selection so the user can drag across monitors).
  Future<ScreenCapture?> captureScreen({bool allDisplays = false}) async {
    final result = await _channel.invokeMethod<Map>('captureScreen', {
      'allDisplays': allDisplays,
    });
    if (result == null) return null;
    return ScreenCapture(
      bytes: result['bytes'] as Uint8List,
      pixelWidth: (result['pixelWidth'] as num).toInt(),
      pixelHeight: (result['pixelHeight'] as num).toInt(),
      bytesPerRow: (result['bytesPerRow'] as num).toInt(),
      screenSize: Size(
        (result['screenWidth'] as num).toDouble(),
        (result['screenHeight'] as num).toDouble(),
      ),
      screenOrigin: Offset(
        (result['screenOriginX'] as num).toDouble(),
        (result['screenOriginY'] as num).toDouble(),
      ),
    );
  }

  /// Check macOS accessibility trust. When [prompt] is true, shows the TCC
  /// system dialog if not yet trusted. Returns true if accessibility is granted.
  Future<bool> checkAccessibility({bool prompt = false}) async {
    final result = await _channel.invokeMethod<bool>('checkAccessibility', {
      'prompt': prompt,
    });
    return result ?? false;
  }

  /// Install global + local Esc key monitors on the native side.
  /// Fires [onEscPressed] when Escape is pressed anywhere, even when the
  /// overlay window isn't visible yet (capture setup phase).
  Future<void> startEscMonitor() async {
    await _channel.invokeMethod('startEscMonitor');
  }

  /// Remove the native Esc key monitors. Safe to call even if not monitoring.
  Future<void> stopEscMonitor() async {
    await _channel.invokeMethod('stopEscMonitor');
  }

  /// Start background polling for window/element rects on a native background
  /// thread. Results are delivered periodically via [onRectsUpdated].
  Future<void> startRectPolling() async {
    await _channel.invokeMethod('startRectPolling');
  }

  /// Stop background rect polling. Safe to call even if not polling.
  Future<void> stopRectPolling() async {
    await _channel.invokeMethod('stopRectPolling');
  }

  /// Fetch visible on-screen windows (excluding our own) in front-to-back Z-order.
  /// Coordinates are in CG points (top-left origin) matching Flutter logical coords.
  /// Prefer using pre-cached rects from [startRectPolling] when available.
  Future<List<DetectedWindow>> getWindowList() async {
    final List<dynamic>? rawList = await _channel.invokeMethod<List<dynamic>>(
      'getWindowList',
    );
    if (rawList == null) return [];

    return rawList.map((entry) {
      final map = Map<String, dynamic>.from(entry as Map);
      return DetectedWindow(
        rect: Rect.fromLTWH(
          (map['x'] as num).toDouble(),
          (map['y'] as num).toDouble(),
          (map['width'] as num).toDouble(),
          (map['height'] as num).toDouble(),
        ),
      );
    }).toList();
  }

  /// Real-time AX hit-test: find the deepest accessible element at [cgPoint]
  /// (global CG coordinates, top-left origin). Returns the element's rect
  /// or `null` if nothing meaningful was found. Much more reliable than
  /// pre-walking the entire AX tree (which can hit the 10 000-rect cap
  /// before reaching some apps like Codex).
  Future<Rect?> hitTestElement(Offset cgPoint) async {
    final result = await _channel.invokeMethod<Map>('hitTestElement', {
      'x': cgPoint.dx,
      'y': cgPoint.dy,
    });
    if (result == null) return null;
    return Rect.fromLTWH(
      (result['x'] as num).toDouble(),
      (result['y'] as num).toDouble(),
      (result['width'] as num).toDouble(),
      (result['height'] as num).toDouble(),
    );
  }

  /// Capture a rectangular region of the screen (all visible content).
  /// [region] is in CG coordinates (top-left origin).
  /// Returns raw BGRA pixel data, or null if capture fails.
  Future<ScreenCapture?> captureRegion(Rect region) async {
    final result = await _channel.invokeMethod<Map>('captureRegion', {
      'x': region.left,
      'y': region.top,
      'width': region.width,
      'height': region.height,
    });
    if (result == null) return null;
    return ScreenCapture(
      bytes: result['bytes'] as Uint8List,
      pixelWidth: (result['pixelWidth'] as num).toInt(),
      pixelHeight: (result['pixelHeight'] as num).toInt(),
      bytesPerRow: (result['bytesPerRow'] as num).toInt(),
      screenSize: Size(
        (result['screenWidth'] as num).toDouble(),
        (result['screenHeight'] as num).toDouble(),
      ),
      screenOrigin: Offset(
        (result['screenOriginX'] as num).toDouble(),
        (result['screenOriginY'] as num).toDouble(),
      ),
    );
  }

  /// Show a small native NSPanel covering [cgRect] (CG coordinates) so the
  /// "Done" button in the Flutter overlay becomes clickable.  The overlay
  /// window has `ignoresMouseEvents = true` for scroll passthrough; this
  /// separate panel provides the click target.
  Future<void> showScrollStopButton(Rect cgRect) async {
    await _channel.invokeMethod('showScrollStopButton', {
      'x': cgRect.left,
      'y': cgRect.top,
      'width': cgRect.width,
      'height': cgRect.height,
    });
  }

  /// Remove the native scroll-stop button panel.
  Future<void> hideScrollStopButton() async {
    await _channel.invokeMethod('hideScrollStopButton');
  }

  /// Transition the full-screen overlay to scroll capture mode.
  /// Keeps the window at full-screen size but makes it non-interactive
  /// (`ignoresMouseEvents = true`) and transparent. The Flutter widget
  /// renders the rainbow border and live preview panel.
  Future<void> enterScrollCaptureMode() async {
    await _channel.invokeMethod('enterScrollCaptureMode');
  }

  /// Show scroll capture preview: fixed window sized for tall images.
  /// Uses 50% screen width × 75% screen height.
  Future<void> showScrollPreview({
    required int imageWidth,
    required int imageHeight,
    required Size screenSize,
    required Offset screenOrigin,
  }) async {
    if (imageWidth <= 0 || imageHeight <= 0) return;

    // Ensure hidden before cleanup to avoid transition flash.
    await windowManager.hide();
    // Same as showPreview(): cleanup without style restoration to prevent flash.
    await _channel.invokeMethod('cleanupOverlayMode');

    final maxW = screenSize.width * 0.8;
    final maxH = screenSize.height * 0.85;

    // Size to image aspect ratio, clamped to screen bounds.
    // Tall scroll captures will naturally be constrained by maxH
    // and the Flutter widget provides scrolling.
    final imageAspect = imageWidth / imageHeight;
    var winW = imageWidth.toDouble();
    var winH = imageHeight.toDouble();

    if (winW > maxW) {
      winW = maxW;
      winH = winW / imageAspect;
    }
    if (winH > maxH) {
      winH = maxH;
      winW = winH * imageAspect;
    }

    winW = winW.clamp(_minPreviewSize.width, maxW);
    winH = winH.clamp(_minPreviewSize.height, maxH);

    final previewSize = Size(winW, winH);

    await windowManager.setMinimumSize(const Size(0, 0));
    await windowManager.setMaximumSize(
      Size(screenSize.width, screenSize.height),
    );
    await windowManager.setTitleBarStyle(
      TitleBarStyle.hidden,
      windowButtonVisibility: false,
    );
    await windowManager.setSize(previewSize);
    await windowManager.setMinimumSize(previewSize);
    await windowManager.setMaximumSize(previewSize);
    await windowManager.setAlwaysOnTop(true);
    await windowManager.setSkipTaskbar(true);
    await windowManager.setHasShadow(true);

    final x = screenOrigin.dx + (screenSize.width - previewSize.width) / 2;
    final y = screenOrigin.dy + (screenSize.height - previewSize.height) / 2;
    await windowManager.setPosition(Offset(x, y));

    // Restore opacity right before show — cleanupOverlayState leaves alpha=0
    // to prevent flash during styleMask restoration.
    await windowManager.setOpacity(1.0);
    await windowManager.show();
    await _focusAndActivateWindow();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await _focusAndActivateWindow();
  }

  Future<void> hidePreview() async {
    // Hide only — defer overlay cleanup to the next showPreview() call.
    // Restoring styleMask on a "hidden" window can still flash because macOS
    // may briefly redisplay the window when styleMask changes.
    await windowManager.hide();
    // Window is already invisible — no need to block on this.
    unawaited(windowManager.setAlwaysOnTop(false));
  }

  Future<void> _focusAndActivateWindow() async {
    await windowManager.focus();
    // Accessory apps can be visible but not active; activate explicitly so
    // keyboard events (Esc, shortcuts) route to our window immediately.
    await _channel.invokeMethod('activateApp');
  }
}
