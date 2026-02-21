import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../widgets/magnifier_loupe.dart';

/// Fullscreen overlay for region selection (Snipaste-style).
///
/// Displays the captured screenshot as an opaque background with a
/// semi-transparent scrim on top. Dragging draws a selection rectangle
/// that cuts through the scrim to reveal the original screenshot.
class RegionSelectionScreen extends StatefulWidget {
  final Uint8List fullScreenBytes;
  final VoidCallback onCancel;
  final void Function(Rect selectionRect) onRegionSelected;

  const RegionSelectionScreen({
    super.key,
    required this.fullScreenBytes,
    required this.onCancel,
    required this.onRegionSelected,
  });

  @override
  State<RegionSelectionScreen> createState() => _RegionSelectionScreenState();
}

class _RegionSelectionScreenState extends State<RegionSelectionScreen> {
  final _focusNode = FocusNode();
  ui.Image? _decodedImage;

  Offset? _start;
  Offset _current = Offset.zero;
  bool _isDragging = false;

  @override
  void initState() {
    super.initState();
    _decodeImage();
  }

  Future<void> _decodeImage() async {
    final codec = await ui.instantiateImageCodec(widget.fullScreenBytes);
    final frame = await codec.getNextFrame();
    if (mounted) {
      setState(() => _decodedImage = frame.image);
    } else {
      frame.image.dispose();
    }
    codec.dispose();
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _decodedImage?.dispose();
    super.dispose();
  }

  Rect? get _selectionRect {
    if (_start == null) return null;
    return Rect.fromPoints(_start!, _current);
  }

  void _onPointerDown(PointerDownEvent event) {
    setState(() {
      _start = event.localPosition;
      _current = event.localPosition;
      _isDragging = true;
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
      // Selection too small — reset
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
          setState(() => _current = event.localPosition);
        },
        child: Listener(
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerUp,
          child: Stack(
            children: [
              // Background: captured screenshot (fills entire screen)
              Positioned.fill(
                child: Image.memory(
                  widget.fullScreenBytes,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                ),
              ),
              // Overlay: scrim + crosshair + selection cutout
              Positioned.fill(
                child: CustomPaint(
                  painter: _SelectionPainter(
                    selectionRect: _selectionRect,
                    cursorPosition: _current,
                    isDragging: _isDragging,
                    devicePixelRatio: dpr,
                  ),
                ),
              ),
              // Magnifier loupe (only shown after image decode)
              if (_decodedImage != null)
                MagnifierLoupe(
                  sourceImage: _decodedImage!,
                  cursorPosition: _current,
                  devicePixelRatio: dpr,
                  screenSize: screenSize,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SelectionPainter extends CustomPainter {
  final Rect? selectionRect;
  final Offset cursorPosition;
  final bool isDragging;
  final double devicePixelRatio;

  _SelectionPainter({
    required this.selectionRect,
    required this.cursorPosition,
    required this.isDragging,
    required this.devicePixelRatio,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final fullRect = Rect.fromLTWH(0, 0, size.width, size.height);

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
    } else {
      // Full scrim when not dragging
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
  }

  void _drawDimensionLabel(
    Canvas canvas, Rect selection, String text, Size canvasSize,
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
        cursorPosition != oldDelegate.cursorPosition ||
        isDragging != oldDelegate.isDragging;
  }
}
