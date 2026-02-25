import 'dart:math';
import 'dart:ui';

import 'annotation.dart';

/// Returns the index of the topmost annotation whose stroke is within
/// [threshold] of [point], or null if none.
///
/// Iterates last-to-first (topmost drawn = highest index).
int? hitTestAnnotations(
  Offset point,
  List<Annotation> annotations, {
  double threshold = 6,
}) {
  for (int i = annotations.length - 1; i >= 0; i--) {
    if (_hitTestShape(point, annotations[i], threshold)) return i;
  }
  return null;
}

bool _hitTestShape(Offset point, Annotation annotation, double threshold) {
  // Use stroke width as minimum threshold.
  final t = max(threshold, annotation.strokeWidth / 2 + 2);
  switch (annotation.type) {
    case ShapeType.rectangle:
      return _distanceToRect(point, annotation) <= t;
    case ShapeType.ellipse:
      return _distanceToEllipse(point, annotation) <= t;
    case ShapeType.line:
    case ShapeType.arrow:
      if (annotation.controlPoints.isEmpty) {
        return distanceToLineSegment(point, annotation.start, annotation.end) <=
            t;
      }
      return _distanceToBezier(point, annotation) <= t;
    case ShapeType.pencil:
    case ShapeType.marker:
      return _distanceToPolyline(point, annotation) <= t;
    case ShapeType.mosaic:
      final mosaicRect = Rect.fromPoints(annotation.start, annotation.end);
      return mosaicRect.inflate(2).contains(point);
    case ShapeType.number:
      return (point - annotation.start).distance <= annotation.stampRadius + 2;
    case ShapeType.text:
      // Hit test against the text bounding box with padding.
      final textRect = annotation.boundingRect.inflate(t);
      return textRect.contains(point);
  }
}

/// Distance from [point] to the nearest edge of a rectangle.
double _distanceToRect(Offset point, Annotation a) {
  final rect = Rect.fromPoints(a.start, a.end);
  // Check distance to each of the 4 edges.
  return [
    distanceToLineSegment(point, rect.topLeft, rect.topRight),
    distanceToLineSegment(point, rect.topRight, rect.bottomRight),
    distanceToLineSegment(point, rect.bottomRight, rect.bottomLeft),
    distanceToLineSegment(point, rect.bottomLeft, rect.topLeft),
  ].reduce(min);
}

/// Distance from [point] to ellipse perimeter.
double _distanceToEllipse(Offset point, Annotation a) {
  final rect = Rect.fromPoints(a.start, a.end);
  final cx = rect.center.dx;
  final cy = rect.center.dy;
  final rx = rect.width / 2;
  final ry = rect.height / 2;
  if (rx < 1 || ry < 1) return double.infinity;

  // Normalize point relative to center.
  final dx = point.dx - cx;
  final dy = point.dy - cy;

  // Angle to nearest point on ellipse.
  final angle = atan2(dy / ry, dx / rx);
  final nearestX = cx + rx * cos(angle);
  final nearestY = cy + ry * sin(angle);
  return (point - Offset(nearestX, nearestY)).distance;
}

/// Distance from [point] to Bézier curve (sampled as line segments).
double _distanceToBezier(Offset point, Annotation a) {
  // Approximate the curve with line segments and find minimum distance.
  const segments = 32;
  double minDist = double.infinity;
  Offset prev = evaluateBezier(a, 0);
  for (int i = 1; i <= segments; i++) {
    final t = i / segments;
    final curr = evaluateBezier(a, t);
    final d = distanceToLineSegment(point, prev, curr);
    if (d < minDist) minDist = d;
    prev = curr;
  }
  return minDist;
}

/// Evaluate the Bézier curve at parameter [t] (0..1).
Offset evaluateBezier(Annotation a, double t) {
  final cps = a.controlPoints;
  if (cps.isEmpty) {
    return Offset.lerp(a.start, a.end, t)!;
  } else if (cps.length == 1) {
    // Quadratic Bézier: (1-t)²P0 + 2t(1-t)P1 + t²P2
    final mt = 1 - t;
    return a.start * (mt * mt) + cps[0] * (2 * mt * t) + a.end * (t * t);
  } else {
    // Cubic Bézier: (1-t)³P0 + 3t(1-t)²P1 + 3t²(1-t)P2 + t³P3
    final mt = 1 - t;
    return a.start * (mt * mt * mt) +
        cps[0] * (3 * mt * mt * t) +
        cps[1] * (3 * mt * t * t) +
        a.end * (t * t * t);
  }
}

/// Distance from [point] to a freehand polyline path.
double _distanceToPolyline(Offset point, Annotation a) {
  final pts = a.points;
  if (pts.length < 2) return double.infinity;
  double minDist = double.infinity;
  for (int i = 0; i < pts.length - 1; i++) {
    final d = distanceToLineSegment(point, pts[i], pts[i + 1]);
    if (d < minDist) minDist = d;
  }
  return minDist;
}

/// Distance from [point] to line segment [a]-[b].
double distanceToLineSegment(Offset point, Offset a, Offset b) {
  final ab = b - a;
  final lengthSq = ab.dx * ab.dx + ab.dy * ab.dy;
  if (lengthSq < 0.001) return (point - a).distance;
  final t = ((point - a).dx * ab.dx + (point - a).dy * ab.dy) / lengthSq;
  final clamped = t.clamp(0.0, 1.0);
  final closest = Offset(a.dx + clamped * ab.dx, a.dy + clamped * ab.dy);
  return (point - closest).distance;
}
