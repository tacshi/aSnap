import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// An 8× magnifier loupe that shows a zoomed view of the source image
/// centered on the cursor position, with a crosshair and pixel coordinates.
class MagnifierLoupe extends StatelessWidget {
  final ui.Image sourceImage;
  final Offset cursorPosition;
  final double devicePixelRatio;
  final Size screenSize;

  static const double loupeSize = 140;
  static const double zoomFactor = 8;
  static const double cursorOffset = 20;

  const MagnifierLoupe({
    super.key,
    required this.sourceImage,
    required this.cursorPosition,
    required this.devicePixelRatio,
    required this.screenSize,
  });

  @override
  Widget build(BuildContext context) {
    final loupeOffset = _computeOffset();
    final physicalX = (cursorPosition.dx * devicePixelRatio).round();
    final physicalY = (cursorPosition.dy * devicePixelRatio).round();

    return Positioned(
      left: loupeOffset.dx,
      top: loupeOffset.dy,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Magnifier
          Container(
            width: loupeSize,
            height: loupeSize,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white, width: 1),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x80000000),
                  blurRadius: 8,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(7),
              child: CustomPaint(
                size: const Size(loupeSize, loupeSize),
                painter: _LoupePainter(
                  image: sourceImage,
                  cursorPosition: cursorPosition,
                  devicePixelRatio: devicePixelRatio,
                  zoomFactor: zoomFactor,
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          // Coordinate label (painted via CustomPaint to bypass macOS data detectors)
          CustomPaint(
            size: Size(loupeSize, 20),
            painter: _CoordinateLabelPainter(text: '$physicalX, $physicalY'),
          ),
        ],
      ),
    );
  }

  Offset _computeOffset() {
    var dx = cursorPosition.dx + cursorOffset;
    var dy = cursorPosition.dy - loupeSize / 2 - 16;

    // Flip horizontally if near right edge
    if (dx + loupeSize > screenSize.width) {
      dx = cursorPosition.dx - cursorOffset - loupeSize;
    }
    // Flip vertically if near top edge
    if (dy < 0) {
      dy = cursorPosition.dy + cursorOffset;
    }
    // Clamp within screen
    dx = dx.clamp(0, screenSize.width - loupeSize);
    dy = dy.clamp(0, screenSize.height - loupeSize - 24);

    return Offset(dx, dy);
  }
}

class _LoupePainter extends CustomPainter {
  final ui.Image image;
  final Offset cursorPosition;
  final double devicePixelRatio;
  final double zoomFactor;

  _LoupePainter({
    required this.image,
    required this.cursorPosition,
    required this.devicePixelRatio,
    required this.zoomFactor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // How many physical pixels one side of the loupe covers at this zoom
    final sampleSize = size.width * devicePixelRatio / zoomFactor;

    // Center the sample on the cursor's physical position
    final physX = cursorPosition.dx * devicePixelRatio;
    final physY = cursorPosition.dy * devicePixelRatio;

    final srcRect = Rect.fromCenter(
      center: Offset(physX, physY),
      width: sampleSize,
      height: sampleSize,
    );

    // Clamp source rect to image bounds
    final clampedSrc = Rect.fromLTRB(
      srcRect.left.clamp(0, image.width.toDouble()),
      srcRect.top.clamp(0, image.height.toDouble()),
      srcRect.right.clamp(0, image.width.toDouble()),
      srcRect.bottom.clamp(0, image.height.toDouble()),
    );

    final dstRect = Rect.fromLTWH(0, 0, size.width, size.height);

    // Draw zoomed image
    canvas.drawImageRect(
      image,
      clampedSrc,
      dstRect,
      Paint()..filterQuality = FilterQuality.none,
    );

    // Draw crosshair (dark shadow + white foreground for visibility on any background)
    final center = size.center(Offset.zero);
    final shadowPaint = Paint()
      ..color = const Color(0x99000000)
      ..strokeWidth = 1.5;
    final crosshairPaint = Paint()
      ..color = const Color(0xCCFFFFFF)
      ..strokeWidth = 0.5;

    // Shadow
    canvas.drawLine(
      Offset(0, center.dy),
      Offset(size.width, center.dy),
      shadowPaint,
    );
    canvas.drawLine(
      Offset(center.dx, 0),
      Offset(center.dx, size.height),
      shadowPaint,
    );
    // Foreground
    canvas.drawLine(
      Offset(0, center.dy),
      Offset(size.width, center.dy),
      crosshairPaint,
    );
    canvas.drawLine(
      Offset(center.dx, 0),
      Offset(center.dx, size.height),
      crosshairPaint,
    );
  }

  @override
  bool shouldRepaint(_LoupePainter oldDelegate) {
    return cursorPosition != oldDelegate.cursorPosition;
  }
}

class _CoordinateLabelPainter extends CustomPainter {
  final String text;

  _CoordinateLabelPainter({required this.text});

  @override
  void paint(Canvas canvas, Size size) {
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
    final bgX = (size.width - bgW) / 2;

    final bgRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(bgX, 0, bgW, bgH),
      const Radius.circular(4),
    );
    canvas.drawRRect(bgRect, Paint()..color = const Color(0xCC000000));
    tp.paint(canvas, Offset(bgX + 8, 3));
  }

  @override
  bool shouldRepaint(_CoordinateLabelPainter oldDelegate) {
    return text != oldDelegate.text;
  }
}
