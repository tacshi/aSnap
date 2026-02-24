import 'dart:ui';

/// The type of shape annotation.
enum ShapeType { rectangle, ellipse, arrow, line }

/// Immutable representation of a single drawn annotation.
///
/// Coordinates are in **image pixel space** (not screen space) so they
/// composite correctly at any zoom level and resolution.
class Annotation {
  final ShapeType type;

  /// Start and end points in image pixel coordinates.
  /// Rectangle/ellipse: opposite corners of the bounding box.
  /// Arrow/line: start point and end point (arrowhead at [end]).
  final Offset start;
  final Offset end;

  final Color color;
  final double strokeWidth;

  /// Corner radius for rectangles (0 = sharp corners).
  final double cornerRadius;

  /// Whether the shape is constrained (e.g. Shift held for circle).
  final bool constrained;

  /// Bézier control points for lines/arrows (max 2).
  /// 1 control point = quadratic, 2 = cubic.
  final List<Offset> controlPoints;

  const Annotation({
    required this.type,
    required this.start,
    required this.end,
    required this.color,
    required this.strokeWidth,
    this.cornerRadius = 0,
    this.constrained = false,
    this.controlPoints = const [],
  });

  Rect get boundingRect => Rect.fromPoints(start, end);

  Annotation withEnd(Offset newEnd) => Annotation(
    type: type,
    start: start,
    end: newEnd,
    color: color,
    strokeWidth: strokeWidth,
    cornerRadius: cornerRadius,
    constrained: constrained,
    controlPoints: controlPoints,
  );

  Annotation withConstrained(bool value) => Annotation(
    type: type,
    start: start,
    end: end,
    color: color,
    strokeWidth: strokeWidth,
    cornerRadius: cornerRadius,
    constrained: value,
    controlPoints: controlPoints,
  );

  /// Returns a copy with the control point at [index] replaced by [point].
  Annotation withControlPoint(int index, Offset point) {
    final updated = [...controlPoints];
    updated[index] = point;
    return Annotation(
      type: type,
      start: start,
      end: end,
      color: color,
      strokeWidth: strokeWidth,
      cornerRadius: cornerRadius,
      constrained: constrained,
      controlPoints: updated,
    );
  }

  /// Returns a copy with [point] appended (no-op if already at max of 2).
  Annotation addControlPoint(Offset point) {
    if (controlPoints.length >= 2) return this;
    return Annotation(
      type: type,
      start: start,
      end: end,
      color: color,
      strokeWidth: strokeWidth,
      cornerRadius: cornerRadius,
      constrained: constrained,
      controlPoints: [...controlPoints, point],
    );
  }

  /// Returns a copy with the control point at [index] removed.
  Annotation removeControlPoint(int index) {
    final updated = [...controlPoints]..removeAt(index);
    return Annotation(
      type: type,
      start: start,
      end: end,
      color: color,
      strokeWidth: strokeWidth,
      cornerRadius: cornerRadius,
      constrained: constrained,
      controlPoints: updated,
    );
  }
}
