import 'package:flutter/services.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

/// A visible on-screen window detected via CGWindowListCopyWindowInfo.
class DetectedWindow {
  final Rect rect;
  const DetectedWindow({required this.rect});
}

/// Screenshot bytes + the captured display's logical size and CG origin.
class ScreenCapture {
  final Uint8List bytes;

  /// Logical (point) size of the captured display.
  final Size screenSize;

  /// Top-left origin of this display in global CG coordinates.
  final Offset screenOrigin;

  const ScreenCapture({
    required this.bytes,
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
  }) async {
    if (imageWidth <= 0 || imageHeight <= 0) return;

    // Exit overlay mode first in case we're coming from region selection
    await _channel.invokeMethod('exitOverlayMode');

    final display = await screenRetriever.getPrimaryDisplay();
    final screenSize = display.size;

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

    final x = (screenSize.width - previewSize.width) / 2;
    final y = (screenSize.height - previewSize.height) / 2;
    await windowManager.setPosition(Offset(x, y));

    await windowManager.show();
    await windowManager.focus();
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

  Future<void> hidePreview() async {
    // Hide only — defer exitOverlayMode to the next showPreview() call.
    // Restoring styleMask on a "hidden" window can still flash because macOS
    // may briefly redisplay the window when styleMask changes.
    await windowManager.hide();
    await windowManager.setAlwaysOnTop(false);
  }
}
