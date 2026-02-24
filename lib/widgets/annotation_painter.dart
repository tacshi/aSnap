import 'dart:math';
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

  AnnotationPainter({
    required this.annotations,
    this.activeAnnotation,
    this.selectedIndex,
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
    // Freehand types get a bounding box highlight instead of handles.
    if (annotation.isFreehand) {
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
        selectedIndex != oldDelegate.selectedIndex;
  }
}
