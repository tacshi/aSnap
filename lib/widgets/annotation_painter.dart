import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/annotation.dart';
import '../models/annotation_handle.dart';

/// Paints committed annotations and an optional in-progress shape.
///
/// Coordinates are in image pixel space — the caller must ensure the
/// canvas is sized/transformed to match the image dimensions.
class AnnotationPainter extends CustomPainter {
  final List<Annotation> annotations;
  final Annotation? activeAnnotation;
  final int? selectedIndex;
  final ui.Image? sourceImage; // Original screenshot for mosaic/blur
  final ByteData? sourcePixels; // Raw RGBA pixels for mosaic pixelation
  final Offset sourceImageOffset; // Annotation-space origin in sourceImage.

  AnnotationPainter({
    required this.annotations,
    this.activeAnnotation,
    this.selectedIndex,
    this.sourceImage,
    this.sourcePixels,
    this.sourceImageOffset = Offset.zero,
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (final annotation in annotations) {
      _drawAnnotation(canvas, annotation);
    }
    if (activeAnnotation != null) {
      _drawAnnotation(canvas, activeAnnotation!);
    }
    // Draw handles for the selected annotation.
    if (selectedIndex != null && selectedIndex! < annotations.length) {
      _drawSelectionHandles(canvas, annotations[selectedIndex!]);
    }
  }

  void _drawAnnotation(Canvas canvas, Annotation annotation) {
    final paint = Paint()
      ..color = annotation.color
      ..style = PaintingStyle.stroke
      ..strokeWidth = annotation.strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    switch (annotation.type) {
      case ShapeType.rectangle:
        final rect = _normalizedRect(annotation);
        if (annotation.cornerRadius > 0) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              rect,
              Radius.circular(annotation.cornerRadius),
            ),
            paint,
          );
        } else {
          canvas.drawRect(rect, paint);
        }

      case ShapeType.ellipse:
        final rect = _ellipseRect(annotation);
        canvas.drawOval(rect, paint);

      case ShapeType.line:
        if (annotation.controlPoints.isEmpty) {
          canvas.drawLine(annotation.start, annotation.end, paint);
        } else {
          canvas.drawPath(_bezierPath(annotation), paint);
        }

      case ShapeType.arrow:
        if (annotation.controlPoints.isEmpty) {
          _drawArrow(canvas, annotation.start, annotation.end, paint);
        } else {
          _drawCurvedArrow(canvas, annotation, paint);
        }

      case ShapeType.pencil:
        _drawPolyline(canvas, annotation, paint);

      case ShapeType.marker:
        _drawMarker(canvas, annotation, paint);

      case ShapeType.mosaic:
        _drawMosaic(canvas, annotation);

      case ShapeType.number:
        _drawNumberStamp(canvas, annotation);

      case ShapeType.text:
        _drawText(canvas, annotation);
    }
  }

  /// Normalized rect that handles backwards drags (right-to-left, bottom-to-top).
  static Rect _normalizedRect(Annotation annotation) {
    return Rect.fromPoints(annotation.start, annotation.end);
  }

  /// Compute the ellipse bounding rect, constraining to a circle when needed.
  static Rect _ellipseRect(Annotation annotation) {
    if (!annotation.constrained) {
      return Rect.fromPoints(annotation.start, annotation.end);
    }
    // Constrained: equal width/height, preserving drag direction.
    final dx = (annotation.end.dx - annotation.start.dx).abs();
    final dy = (annotation.end.dy - annotation.start.dy).abs();
    final side = min(dx, dy);
    final signX = (annotation.end.dx - annotation.start.dx).sign;
    final signY = (annotation.end.dy - annotation.start.dy).sign;
    return Rect.fromPoints(
      annotation.start,
      Offset(
        annotation.start.dx + side * (signX == 0 ? 1 : signX),
        annotation.start.dy + side * (signY == 0 ? 1 : signY),
      ),
    );
  }

  static Path _bezierPath(Annotation a) {
    final path = Path()..moveTo(a.start.dx, a.start.dy);
    if (a.controlPoints.length == 1) {
      final cp = a.controlPoints[0];
      path.quadraticBezierTo(cp.dx, cp.dy, a.end.dx, a.end.dy);
    } else if (a.controlPoints.length >= 2) {
      final cp1 = a.controlPoints[0];
      final cp2 = a.controlPoints[1];
      path.cubicTo(cp1.dx, cp1.dy, cp2.dx, cp2.dy, a.end.dx, a.end.dy);
    }
    return path;
  }

  void _drawCurvedArrow(Canvas canvas, Annotation a, Paint paint) {
    // Compute arrowhead direction from curve tangent at t=1.
    final Offset tangentDir;
    if (a.controlPoints.length == 1) {
      tangentDir = a.end - a.controlPoints[0]; // quadratic tangent at t=1
    } else {
      tangentDir = a.end - a.controlPoints[1]; // cubic tangent at t=1
    }
    if (tangentDir.distance < 1) return;
    final unitDir = tangentDir / tangentDir.distance;
    final headLength = paint.strokeWidth * 4;
    final headWidth = paint.strokeWidth * 2;
    final base = a.end - unitDir * headLength;
    final perpendicular = Offset(-unitDir.dy, unitDir.dx);

    // Draw curve up to arrowhead base.
    final curvePath = Path()..moveTo(a.start.dx, a.start.dy);
    if (a.controlPoints.length == 1) {
      final cp = a.controlPoints[0];
      curvePath.quadraticBezierTo(cp.dx, cp.dy, base.dx, base.dy);
    } else {
      final cp1 = a.controlPoints[0];
      final cp2 = a.controlPoints[1];
      curvePath.cubicTo(cp1.dx, cp1.dy, cp2.dx, cp2.dy, base.dx, base.dy);
    }
    canvas.drawPath(curvePath, paint);

    // Filled arrowhead triangle.
    final p1 = base + perpendicular * headWidth;
    final p2 = base - perpendicular * headWidth;
    final headPath = ui.Path()
      ..moveTo(a.end.dx, a.end.dy)
      ..lineTo(p1.dx, p1.dy)
      ..lineTo(p2.dx, p2.dy)
      ..close();
    canvas.drawPath(headPath, Paint()..color = paint.color);
  }

  void _drawArrow(Canvas canvas, Offset from, Offset to, Paint paint) {
    final direction = to - from;
    if (direction.distance < 1) return;

    final unitDir = direction / direction.distance;
    final headLength = paint.strokeWidth * 4;
    final headWidth = paint.strokeWidth * 2;

    final perpendicular = Offset(-unitDir.dy, unitDir.dx);
    final base = to - unitDir * headLength;

    // Draw line only up to the arrowhead base so it doesn't poke through.
    canvas.drawLine(from, base, paint);

    // Filled arrowhead triangle.
    final p1 = base + perpendicular * headWidth;
    final p2 = base - perpendicular * headWidth;
    final path = ui.Path()
      ..moveTo(to.dx, to.dy)
      ..lineTo(p1.dx, p1.dy)
      ..lineTo(p2.dx, p2.dy)
      ..close();
    canvas.drawPath(path, Paint()..color = paint.color);
  }

  static Path? _polylinePath(Annotation a) {
    final pts = a.points;
    if (pts.length < 2) return null;
    final path = Path()..moveTo(pts[0].dx, pts[0].dy);
    for (int i = 1; i < pts.length; i++) {
      path.lineTo(pts[i].dx, pts[i].dy);
    }
    return path;
  }

  void _drawPolyline(Canvas canvas, Annotation a, Paint paint) {
    final path = _polylinePath(a);
    if (path != null) canvas.drawPath(path, paint);
  }

  void _drawMarker(Canvas canvas, Annotation a, Paint paint) {
    final path = _polylinePath(a);
    if (path == null) return;
    // saveLayer with ~40% opacity prevents overlapping stroke from self-darkening.
    canvas.saveLayer(
      null,
      Paint()..color = Color.fromARGB((a.color.a * 0.4 * 255).round(), 0, 0, 0),
    );
    canvas.drawPath(
      path,
      paint
        ..color = a.color.withValues(alpha: 1.0)
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.restore();
  }

  void _drawMosaic(Canvas canvas, Annotation a) {
    final rect = _normalizedRect(a);
    final rrect = a.cornerRadius > 0
        ? RRect.fromRectAndRadius(rect, Radius.circular(a.cornerRadius))
        : RRect.fromRectAndRadius(rect, Radius.zero);

    canvas.save();
    canvas.clipRRect(rrect);

    switch (a.mosaicMode) {
      case MosaicMode.solidColor:
        canvas.drawRect(rect, Paint()..color = a.color);

      case MosaicMode.blur:
        if (sourceImage != null) {
          final sigma = a.strokeWidth * 1.5;
          final matrix = Float64List.fromList([
            1,
            0,
            0,
            0,
            0,
            1,
            0,
            0,
            0,
            0,
            1,
            0,
            -sourceImageOffset.dx,
            -sourceImageOffset.dy,
            0,
            1,
          ]);
          // ImageShader + saveLayer + drawRect avoids drawImage/drawImageRect
          // which fail silently in transformed canvases (translate + scale).
          // The shader maps image pixels 1:1 to local annotation coords.
          // sourceImageOffset aligns local (selection-relative) coords with
          // the correct location in the underlying source image.
          final shader = ui.ImageShader(
            sourceImage!,
            TileMode.clamp,
            TileMode.clamp,
            matrix,
          );
          canvas.saveLayer(
            rect,
            Paint()
              ..imageFilter = ui.ImageFilter.blur(
                sigmaX: sigma,
                sigmaY: sigma,
                tileMode: TileMode.clamp,
              ),
          );
          canvas.drawRect(rect, Paint()..shader = shader);
          canvas.restore();
        }

      case MosaicMode.pixelate:
        if (sourceImage != null && sourcePixels != null) {
          // Sample pixel colors from pre-loaded RGBA ByteData and draw
          // colored blocks. Avoids drawImageRect which fails silently
          // in transformed canvases.
          final imgW = sourceImage!.width;
          final blockSize = a.strokeWidth.clamp(2.0, 50.0);
          final pixels = sourcePixels!;
          for (double y = rect.top; y < rect.bottom; y += blockSize) {
            for (double x = rect.left; x < rect.right; x += blockSize) {
              final bw = (x + blockSize).clamp(rect.left, rect.right) - x;
              final bh = (y + blockSize).clamp(rect.top, rect.bottom) - y;
              final blockRect = Rect.fromLTWH(x, y, bw, bh);
              final cx = (x + bw / 2 + sourceImageOffset.dx)
                  .clamp(0, sourceImage!.width - 1)
                  .toInt();
              final cy = (y + bh / 2 + sourceImageOffset.dy)
                  .clamp(0, sourceImage!.height - 1)
                  .toInt();
              canvas.drawRect(
                blockRect,
                Paint()..color = _samplePixel(pixels, imgW, cx, cy),
              );
            }
          }
        }
    }
    canvas.restore();
  }

  /// Read one pixel from raw RGBA [ByteData].
  static Color _samplePixel(ByteData pixels, int imageWidth, int x, int y) {
    final offset = (y * imageWidth + x) * 4;
    return Color.fromARGB(
      pixels.getUint8(offset + 3),
      pixels.getUint8(offset),
      pixels.getUint8(offset + 1),
      pixels.getUint8(offset + 2),
    );
  }

  void _drawNumberStamp(Canvas canvas, Annotation a) {
    final radius = a.stampRadius;
    final center = a.start;

    // Filled circle.
    canvas.drawCircle(center, radius, Paint()..color = a.color);

    // Number text — white on dark colors, black on light.
    final luminance = a.color.computeLuminance();
    final textColor = luminance > 0.5
        ? const Color(0xFF000000)
        : const Color(0xFFFFFFFF);
    final label = a.label?.toString() ?? '?';
    final fontSize = radius * 1.2;

    final textPainter = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: textColor,
          fontSize: fontSize,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout();

    textPainter.paint(
      canvas,
      Offset(
        center.dx - textPainter.width / 2,
        center.dy - textPainter.height / 2,
      ),
    );
  }

  void _drawText(Canvas canvas, Annotation a) {
    final content = a.text;
    if (content == null || content.isEmpty) return;

    final textPainter = TextPainter(
      text: TextSpan(
        text: content,
        style: TextStyle(
          color: a.color,
          fontSize: a.fontSize,
          fontFamily: a.fontFamily,
        ),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout();

    textPainter.paint(canvas, a.start);
  }

  void _drawFreehandSelectionBox(Canvas canvas, Annotation annotation) {
    final rect = annotation.boundingRect;
    if (rect.isEmpty) return;
    // Expand slightly so the box doesn't sit right on the stroke.
    final expanded = rect.inflate(annotation.strokeWidth / 2 + 4);
    final dashPaint = Paint()
      ..color = annotation.color.withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawRect(expanded, dashPaint);
  }

  void _drawSelectionHandles(Canvas canvas, Annotation annotation) {
    // Freehand types, stamps, and text get a bounding box instead of handles.
    if (annotation.isFreehand || annotation.isStamp || annotation.isText) {
      _drawFreehandSelectionBox(canvas, annotation);
      return;
    }
    final handles = annotationHandles(annotation);
    final handleRadius = max(4.0, annotation.strokeWidth * 0.6);
    for (final handle in handles) {
      final isControlPoint = handle.type == AnnHandleType.controlPoint;
      // White fill with shape-colored border.
      canvas.drawCircle(
        handle.position,
        handleRadius,
        Paint()..color = const Color(0xFFFFFFFF),
      );
      canvas.drawCircle(
        handle.position,
        handleRadius,
        Paint()
          ..color = isControlPoint
              ? const Color(0xFF2979FF) // blue for control points
              : annotation.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
    // Draw control polygon guide lines (after all handles are drawn).
    final cps = annotation.controlPoints;
    if (cps.isNotEmpty &&
        (annotation.type == ShapeType.line ||
            annotation.type == ShapeType.arrow)) {
      final guidePaint = Paint()
        ..color = const Color(0xFF2979FF).withValues(alpha: 0.4)
        ..strokeWidth = 1;
      // Control polygon: start → cp0 → [cp1 →] end
      canvas.drawLine(annotation.start, cps[0], guidePaint);
      if (cps.length == 1) {
        canvas.drawLine(cps[0], annotation.end, guidePaint);
      } else {
        canvas.drawLine(cps[0], cps[1], guidePaint);
        canvas.drawLine(cps[1], annotation.end, guidePaint);
      }
    }
  }

  @override
  bool shouldRepaint(AnnotationPainter oldDelegate) {
    return !identical(annotations, oldDelegate.annotations) ||
        activeAnnotation != oldDelegate.activeAnnotation ||
        selectedIndex != oldDelegate.selectedIndex ||
        !identical(sourceImage, oldDelegate.sourceImage) ||
        !identical(sourcePixels, oldDelegate.sourcePixels) ||
        sourceImageOffset != oldDelegate.sourceImageOffset;
  }
}
