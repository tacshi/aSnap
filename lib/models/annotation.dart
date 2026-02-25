import 'dart:ui';

import 'package:flutter/foundation.dart';

/// The mosaic/blur mode for mosaic annotations.
enum MosaicMode { pixelate, blur, solidColor }

/// The type of shape annotation.
enum ShapeType {
  rectangle,
  ellipse,
  arrow,
  line,
  pencil,
  marker,
  mosaic,
  number,
  text,
}

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

  /// Freehand path points for pencil/marker tools.
  final List<Offset> points;

  /// Number label for stamp annotations (null for other types).
  final int? label;

  /// Text content for text annotations (null for other types).
  final String? text;

  /// Font family for text annotations (null = system default sans-serif).
  final String? fontFamily;

  /// Mosaic mode for mosaic annotations.
  final MosaicMode mosaicMode;

  const Annotation({
    required this.type,
    required this.start,
    required this.end,
    required this.color,
    required this.strokeWidth,
    this.cornerRadius = 0,
    this.constrained = false,
    this.controlPoints = const [],
    this.points = const [],
    this.label,
    this.text,
    this.fontFamily,
    this.mosaicMode = MosaicMode.pixelate,
  });

  /// Whether this annotation is a freehand type (pencil or marker).
  bool get isFreehand => type == ShapeType.pencil || type == ShapeType.marker;

  /// Whether this annotation is a point-placed stamp (no drag sizing).
  bool get isStamp => type == ShapeType.number;

  /// Whether this annotation is a text annotation.
  bool get isText => type == ShapeType.text;

  /// Whether this annotation is a mosaic annotation.
  bool get isMosaic => type == ShapeType.mosaic;

  /// Base font size for text annotations, derived from stroke width.
  double get fontSize => strokeWidth * 4;

  /// Circle radius for number stamps, derived from stroke width.
  double get stampRadius => strokeWidth * 4;

  /// Bounding rect: for freehand types, computed from all path points;
  /// for others, from start/end.
  Rect get boundingRect {
    if (isStamp) {
      final r = stampRadius;
      return Rect.fromCircle(center: start, radius: r);
    }
    if (isFreehand && points.length >= 2) {
      double minX = points[0].dx, maxX = points[0].dx;
      double minY = points[0].dy, maxY = points[0].dy;
      for (int i = 1; i < points.length; i++) {
        final p = points[i];
        if (p.dx < minX) minX = p.dx;
        if (p.dx > maxX) maxX = p.dx;
        if (p.dy < minY) minY = p.dy;
        if (p.dy > maxY) maxY = p.dy;
      }
      return Rect.fromLTRB(minX, minY, maxX, maxY);
    }
    return Rect.fromPoints(start, end);
  }

  // ---------------------------------------------------------------------------
  // copyWith
  // ---------------------------------------------------------------------------

  /// Returns a copy with any subset of fields overridden.
  Annotation copyWith({
    ShapeType? type,
    Offset? start,
    Offset? end,
    Color? color,
    double? strokeWidth,
    double? cornerRadius,
    bool? constrained,
    List<Offset>? controlPoints,
    List<Offset>? points,
    int? label,
    String? text,
    String? fontFamily,
    MosaicMode? mosaicMode,
  }) {
    return Annotation(
      type: type ?? this.type,
      start: start ?? this.start,
      end: end ?? this.end,
      color: color ?? this.color,
      strokeWidth: strokeWidth ?? this.strokeWidth,
      cornerRadius: cornerRadius ?? this.cornerRadius,
      constrained: constrained ?? this.constrained,
      controlPoints: controlPoints ?? this.controlPoints,
      points: points ?? this.points,
      label: label ?? this.label,
      text: text ?? this.text,
      fontFamily: fontFamily ?? this.fontFamily,
      mosaicMode: mosaicMode ?? this.mosaicMode,
    );
  }

  // ---------------------------------------------------------------------------
  // Convenience copy methods
  // ---------------------------------------------------------------------------

  Annotation withEnd(Offset newEnd) => copyWith(end: newEnd);

  Annotation withConstrained(bool value) => copyWith(constrained: value);

  /// Returns a copy with the control point at [index] replaced by [point].
  Annotation withControlPoint(int index, Offset point) {
    final updated = [...controlPoints];
    updated[index] = point;
    return copyWith(controlPoints: updated);
  }

  /// Returns a copy with [point] appended (no-op if already at max of 2).
  Annotation addControlPoint(Offset point) {
    if (controlPoints.length >= 2) return this;
    return copyWith(controlPoints: [...controlPoints, point]);
  }

  /// Returns a copy with the control point at [index] removed.
  Annotation removeControlPoint(int index) {
    final updated = [...controlPoints]..removeAt(index);
    return copyWith(controlPoints: updated);
  }

  /// Returns a copy with [point] appended to the freehand path.
  Annotation appendPoint(Offset point) {
    return copyWith(end: point, points: [...points, point]);
  }

  /// Returns a copy with the given simplified [newPoints] list.
  Annotation withPoints(List<Offset> newPoints) => copyWith(points: newPoints);

  /// Returns a copy with the given [newText] content.
  Annotation withText(String newText) => copyWith(text: newText);

  /// Returns a copy with the given [mode] for mosaic annotations.
  Annotation withMosaicMode(MosaicMode mode) => copyWith(mosaicMode: mode);

  /// Returns a copy with all positions shifted by [delta].
  Annotation translated(Offset delta) {
    return copyWith(
      start: start + delta,
      end: end + delta,
      controlPoints: [for (final cp in controlPoints) cp + delta],
      points: [for (final p in points) p + delta],
    );
  }

  // ---------------------------------------------------------------------------
  // Equality
  // ---------------------------------------------------------------------------

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! Annotation) return false;
    return type == other.type &&
        start == other.start &&
        end == other.end &&
        color == other.color &&
        strokeWidth == other.strokeWidth &&
        cornerRadius == other.cornerRadius &&
        constrained == other.constrained &&
        listEquals(controlPoints, other.controlPoints) &&
        listEquals(points, other.points) &&
        label == other.label &&
        text == other.text &&
        fontFamily == other.fontFamily &&
        mosaicMode == other.mosaicMode;
  }

  @override
  int get hashCode => Object.hash(
    type,
    start,
    end,
    color,
    strokeWidth,
    cornerRadius,
    constrained,
    Object.hashAll(controlPoints),
    Object.hashAll(points),
    label,
    text,
    fontFamily,
    mosaicMode,
  );
}
