import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Fullscreen overlay for region selection (Snipaste-style).
///
/// Displays the captured screenshot as an opaque background with a
/// semi-transparent scrim on top. Dragging draws a selection rectangle
/// that cuts through the scrim to reveal the original screenshot.
class RegionSelectionScreen extends StatefulWidget {
  /// Pre-decoded image for instant display (no async Image.memory decode).
  final ui.Image decodedImage;
  final List<Rect> windowRects;
  final VoidCallback onCancel;
  final void Function(Rect selectionRect) onRegionSelected;

  /// Real-time AX hit-test callback. Takes a local point, returns the deepest
  /// accessible element rect in local coordinates (or null).
  final Future<Rect?> Function(Offset localPoint)? onHitTest;

  const RegionSelectionScreen({
    super.key,
    required this.decodedImage,
    required this.windowRects,
    required this.onCancel,
    required this.onRegionSelected,
    this.onHitTest,
  });

  @override
  State<RegionSelectionScreen> createState() => _RegionSelectionScreenState();
}

class _RegionSelectionScreenState extends State<RegionSelectionScreen> {
  final _focusNode = FocusNode();

  Offset? _start;
  Offset _current = Offset.zero;
  bool _isDragging = false;
  Rect? _detectedWindowRect;

  /// True while a platform-channel AX hit-test is in flight.
  bool _axQueryInFlight = false;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  Rect? get _selectionRect {
    if (_start == null) return null;
    return Rect.fromPoints(_start!, _current);
  }

  /// Hit-test all element rects (windows + AX sub-elements) and return the
  /// smallest one containing [point]. This gives granular Snipaste-style
  /// detection of toolbars, sidebars, browser content areas, etc.
  Rect? _hitTestElement(Offset point) {
    Rect? best;
    double bestArea = double.infinity;
    for (final rect in widget.windowRects) {
      if (rect.contains(point)) {
        final area = rect.width * rect.height;
        if (area < bestArea) {
          bestArea = area;
          best = rect;
        }
      }
    }
    return best;
  }

  Future<void> _fireAxHitTest(Offset queryPoint) async {
    try {
      final rect = await widget.onHitTest?.call(queryPoint);
      if (!mounted || _isDragging) return;
      // Use AX result; fall back to geometric at current cursor position.
      final effective = rect ?? _hitTestElement(_current);
      if (effective != _detectedWindowRect) {
        setState(() {
          _detectedWindowRect = effective;
        });
      }
    } finally {
      _axQueryInFlight = false;
      // If cursor moved while query was in flight, fire another query
      // for the current position so detection stays accurate.
      if (mounted && !_isDragging && widget.onHitTest != null) {
        if ((_current - queryPoint).distance > 5) {
          _axQueryInFlight = true;
          unawaited(_fireAxHitTest(_current));
        }
      }
    }
  }

  void _onPointerDown(PointerDownEvent event) {
    setState(() {
      _start = event.localPosition;
      _current = event.localPosition;
      _isDragging = true;
      _detectedWindowRect = null;
    });
  }

  void _onPointerMove(PointerMoveEvent event) {
    setState(() {
      _current = event.localPosition;
    });
  }

  void _onPointerUp(PointerUpEvent event) {
    if (!_isDragging) return;

    final rect = _selectionRect;
    if (rect != null && rect.width.abs() > 4 && rect.height.abs() > 4) {
      // Normalize to positive rect
      final normalized = Rect.fromLTRB(
        rect.left < rect.right ? rect.left : rect.right,
        rect.top < rect.bottom ? rect.top : rect.bottom,
        rect.left < rect.right ? rect.right : rect.left,
        rect.top < rect.bottom ? rect.bottom : rect.top,
      );
      widget.onRegionSelected(normalized);
    } else {
      // Click (no meaningful drag) — accept detected window or AX element
      final windowRect =
          _detectedWindowRect ?? _hitTestElement(event.localPosition);
      if (windowRect != null) {
        widget.onRegionSelected(windowRect);
      } else if (widget.onHitTest != null) {
        // Try AX hit-test as last resort for click selection.
        unawaited(_tryAxClickSelect(event.localPosition));
      } else {
        setState(() {
          _start = null;
          _isDragging = false;
        });
      }
    }
  }

  Future<void> _tryAxClickSelect(Offset localPoint) async {
    final rect = await widget.onHitTest?.call(localPoint);
    if (!mounted) return;
    if (rect != null) {
      widget.onRegionSelected(rect);
    } else {
      setState(() {
        _start = null;
        _isDragging = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);

    return KeyboardListener(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: (event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          widget.onCancel();
        }
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.precise,
        onHover: (event) {
          if (event.localPosition == _current) return;
          final pos = event.localPosition;
          final hasAxHitTest = widget.onHitTest != null;
          setState(() {
            _current = pos;
            if (!_isDragging && !hasAxHitTest) {
              _detectedWindowRect = _hitTestElement(pos);
            }
          });
          // Throttle AX queries: fire immediately, skip while in-flight.
          // The round-trip (~20-30ms) acts as a natural throttle interval.
          // When the in-flight query returns, it re-fires if cursor moved.
          if (!_isDragging && hasAxHitTest && !_axQueryInFlight) {
            _axQueryInFlight = true;
            unawaited(_fireAxHitTest(pos));
          }
        },
        child: Listener(
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerUp,
          child: Stack(
            children: [
              // Background: pre-decoded screenshot (instant, no async decode)
              // Overlay: scrim + crosshair + selection cutout
              Positioned.fill(
                child: CustomPaint(
                  painter: _SelectionPainter(
                    backgroundImage: widget.decodedImage,
                    selectionRect: _selectionRect,
                    detectedWindowRect: _isDragging
                        ? null
                        : _detectedWindowRect,
                    cursorPosition: _current,
                    isDragging: _isDragging,
                    devicePixelRatio: dpr,
                    screenSize: screenSize,
                  ),
                  isComplex: true,
                  willChange: true,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SelectionPainter extends CustomPainter {
  static const double _loupeSize = 140;
  static const double _loupeZoom = 8;
  static const double _loupeCursorOffset = 20;

  final ui.Image backgroundImage;
  final Rect? selectionRect;
  final Rect? detectedWindowRect;
  final Offset cursorPosition;
  final bool isDragging;
  final double devicePixelRatio;
  final Size screenSize;

  _SelectionPainter({
    required this.backgroundImage,
    required this.selectionRect,
    required this.detectedWindowRect,
    required this.cursorPosition,
    required this.isDragging,
    required this.devicePixelRatio,
    required this.screenSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final fullRect = Rect.fromLTWH(0, 0, size.width, size.height);

    // Force a full-frame replacement on every paint so prior frames don't
    // accumulate when the backing store isn't cleared.
    canvas.saveLayer(fullRect, Paint()..blendMode = BlendMode.src);
    // Opaque base to avoid any transparent pixels leaking previous content.
    canvas.drawRect(fullRect, Paint()..color = Colors.black);

    // Paint the captured screenshot every frame to avoid any accumulation
    // artifacts from semi-transparent overlay strokes.
    final imageSize = Size(
      backgroundImage.width.toDouble(),
      backgroundImage.height.toDouble(),
    );
    final fitted = applyBoxFit(BoxFit.cover, imageSize, size);
    final srcRect = Alignment.center.inscribe(
      fitted.source,
      Offset.zero & imageSize,
    );
    final dstRect = Alignment.center.inscribe(
      fitted.destination,
      Offset.zero & size,
    );
    // Use BlendMode.src to force a full replacement of prior frame contents.
    canvas.drawImageRect(backgroundImage, srcRect, dstRect, Paint());

    // Semi-transparent scrim over the screenshot
    final scrimPaint = Paint()..color = const Color(0x44000000);

    if (selectionRect != null && isDragging) {
      // Scrim with cutout — selection area shows the original screenshot
      final fullPath = Path()..addRect(fullRect);
      final selPath = Path()..addRect(selectionRect!);
      final scrimPath = Path.combine(
        PathOperation.difference,
        fullPath,
        selPath,
      );
      canvas.drawPath(scrimPath, scrimPaint);

      // Selection border
      final borderPaint = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1;
      canvas.drawRect(selectionRect!, borderPaint);

      // Selection dimensions label
      final w = (selectionRect!.width.abs() * devicePixelRatio).round();
      final h = (selectionRect!.height.abs() * devicePixelRatio).round();
      _drawDimensionLabel(canvas, selectionRect!, '$w \u00D7 $h', size);
    } else if (detectedWindowRect != null && !isDragging) {
      // Window detection highlight — scrim with cutout for detected window
      final fullPath = Path()..addRect(fullRect);
      final windowPath = Path()..addRect(detectedWindowRect!);
      final scrimPath = Path.combine(
        PathOperation.difference,
        fullPath,
        windowPath,
      );
      canvas.drawPath(scrimPath, scrimPaint);

      // Border around detected window
      final borderPaint = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      canvas.drawRect(detectedWindowRect!, borderPaint);

      // Dimension label for detected window
      final w = (detectedWindowRect!.width * devicePixelRatio).round();
      final h = (detectedWindowRect!.height * devicePixelRatio).round();
      _drawDimensionLabel(canvas, detectedWindowRect!, '$w \u00D7 $h', size);
    } else {
      // Full scrim when not dragging and no window detected
      canvas.drawRect(fullRect, scrimPaint);
    }

    // Crosshair lines (dark shadow + white foreground for visibility)
    final shadowPaint = Paint()
      ..color = const Color(0x55000000)
      ..strokeWidth = 1;
    final crosshairPaint = Paint()
      ..color = const Color(0xAAFFFFFF)
      ..strokeWidth = 0.5;

    // Horizontal shadow + foreground
    canvas.drawLine(
      Offset(0, cursorPosition.dy),
      Offset(size.width, cursorPosition.dy),
      shadowPaint,
    );
    canvas.drawLine(
      Offset(0, cursorPosition.dy),
      Offset(size.width, cursorPosition.dy),
      crosshairPaint,
    );
    // Vertical shadow + foreground
    canvas.drawLine(
      Offset(cursorPosition.dx, 0),
      Offset(cursorPosition.dx, size.height),
      shadowPaint,
    );
    canvas.drawLine(
      Offset(cursorPosition.dx, 0),
      Offset(cursorPosition.dx, size.height),
      crosshairPaint,
    );

    _paintLoupe(canvas);
    canvas.restore();
  }

  void _paintLoupe(Canvas canvas) {
    final loupeOffset = _computeLoupeOffset();
    final loupeRect = Rect.fromLTWH(
      loupeOffset.dx,
      loupeOffset.dy,
      _loupeSize,
      _loupeSize,
    );
    final loupeRRect = RRect.fromRectAndRadius(
      loupeRect,
      const Radius.circular(8),
    );

    // Shadow
    final loupePath = Path()..addRRect(loupeRRect);
    canvas.drawShadow(loupePath, const Color(0x80000000), 6, true);

    // Clip to loupe shape and draw zoomed pixels
    canvas.save();
    canvas.clipRRect(loupeRRect);

    final sampleSize = _loupeSize * devicePixelRatio / _loupeZoom;
    final physX = cursorPosition.dx * devicePixelRatio;
    final physY = cursorPosition.dy * devicePixelRatio;
    final srcRect = Rect.fromCenter(
      center: Offset(physX, physY),
      width: sampleSize,
      height: sampleSize,
    );
    final clampedSrc = Rect.fromLTRB(
      srcRect.left.clamp(0, backgroundImage.width.toDouble()),
      srcRect.top.clamp(0, backgroundImage.height.toDouble()),
      srcRect.right.clamp(0, backgroundImage.width.toDouble()),
      srcRect.bottom.clamp(0, backgroundImage.height.toDouble()),
    );
    canvas.drawImageRect(
      backgroundImage,
      clampedSrc,
      loupeRect,
      Paint()..filterQuality = FilterQuality.none,
    );

    // Crosshair inside loupe
    final center = loupeRect.center;
    final loupeShadow = Paint()
      ..color = const Color(0x99000000)
      ..strokeWidth = 1.5;
    final loupeCrosshair = Paint()
      ..color = const Color(0xCCFFFFFF)
      ..strokeWidth = 0.5;
    canvas.drawLine(
      Offset(loupeRect.left, center.dy),
      Offset(loupeRect.right, center.dy),
      loupeShadow,
    );
    canvas.drawLine(
      Offset(center.dx, loupeRect.top),
      Offset(center.dx, loupeRect.bottom),
      loupeShadow,
    );
    canvas.drawLine(
      Offset(loupeRect.left, center.dy),
      Offset(loupeRect.right, center.dy),
      loupeCrosshair,
    );
    canvas.drawLine(
      Offset(center.dx, loupeRect.top),
      Offset(center.dx, loupeRect.bottom),
      loupeCrosshair,
    );

    canvas.restore();

    // Border
    final borderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawRRect(loupeRRect, borderPaint);

    // Coordinate label
    final physicalX = (cursorPosition.dx * devicePixelRatio).round();
    final physicalY = (cursorPosition.dy * devicePixelRatio).round();
    _drawLoupeLabel(
      canvas,
      Offset(loupeRect.left, loupeRect.bottom + 4),
      Size(_loupeSize, 20),
      '$physicalX, $physicalY',
    );
  }

  Offset _computeLoupeOffset() {
    var dx = cursorPosition.dx + _loupeCursorOffset;
    var dy = cursorPosition.dy - _loupeSize / 2 - 16;

    if (dx + _loupeSize > screenSize.width) {
      dx = cursorPosition.dx - _loupeCursorOffset - _loupeSize;
    }
    if (dy < 0) {
      dy = cursorPosition.dy + _loupeCursorOffset;
    }
    dx = dx.clamp(0, screenSize.width - _loupeSize);
    dy = dy.clamp(0, screenSize.height - _loupeSize - 24);

    return Offset(dx, dy);
  }

  void _drawLoupeLabel(Canvas canvas, Offset topLeft, Size size, String text) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final bgW = tp.width + 16;
    final bgH = tp.height + 6;
    final bgX = topLeft.dx + (size.width - bgW) / 2;
    final bgRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(bgX, topLeft.dy, bgW, bgH),
      const Radius.circular(4),
    );
    canvas.drawRRect(bgRect, Paint()..color = const Color(0xCC000000));
    tp.paint(canvas, Offset(bgX + 8, topLeft.dy + 3));
  }

  void _drawDimensionLabel(
    Canvas canvas,
    Rect selection,
    String text,
    Size canvasSize,
  ) {
    final textPainter = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final labelW = textPainter.width + 12;
    final labelH = textPainter.height + 6;
    final labelX = selection.center.dx - labelW / 2;
    var labelY = selection.bottom + 6;

    // Flip above selection if label would go off-screen at bottom
    if (labelY + labelH > canvasSize.height) {
      labelY = selection.top - labelH - 6;
    }

    final bgRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(labelX, labelY, labelW, labelH),
      const Radius.circular(4),
    );
    canvas.drawRRect(bgRect, Paint()..color = const Color(0xCC000000));
    textPainter.paint(canvas, Offset(labelX + 6, labelY + 3));
  }

  @override
  bool shouldRepaint(_SelectionPainter oldDelegate) {
    return selectionRect != oldDelegate.selectionRect ||
        detectedWindowRect != oldDelegate.detectedWindowRect ||
        cursorPosition != oldDelegate.cursorPosition ||
        isDragging != oldDelegate.isDragging ||
        screenSize != oldDelegate.screenSize;
  }
}
