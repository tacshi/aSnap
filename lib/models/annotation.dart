import 'dart:ui';

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

  Annotation withEnd(Offset newEnd) => Annotation(
    type: type,
    start: start,
    end: newEnd,
    color: color,
    strokeWidth: strokeWidth,
    cornerRadius: cornerRadius,
    constrained: constrained,
    controlPoints: controlPoints,
    points: points,
    label: label,
    text: text,
    fontFamily: fontFamily,
    mosaicMode: mosaicMode,
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
    points: points,
    label: label,
    text: text,
    fontFamily: fontFamily,
    mosaicMode: mosaicMode,
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
      points: points,
      label: label,
      text: text,
      fontFamily: fontFamily,
      mosaicMode: mosaicMode,
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
      points: points,
      label: label,
      text: text,
      fontFamily: fontFamily,
      mosaicMode: mosaicMode,
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
      points: points,
      label: label,
      text: text,
      fontFamily: fontFamily,
      mosaicMode: mosaicMode,
    );
  }

  /// Returns a copy with [point] appended to the freehand path.
  Annotation appendPoint(Offset point) {
    return Annotation(
      type: type,
      start: start,
      end: point,
      color: color,
      strokeWidth: strokeWidth,
      cornerRadius: cornerRadius,
      constrained: constrained,
      controlPoints: controlPoints,
      points: [...points, point],
      label: label,
      text: text,
      fontFamily: fontFamily,
      mosaicMode: mosaicMode,
    );
  }

  /// Returns a copy with the given simplified [newPoints] list.
  Annotation withPoints(List<Offset> newPoints) {
    return Annotation(
      type: type,
      start: start,
      end: end,
      color: color,
      strokeWidth: strokeWidth,
      cornerRadius: cornerRadius,
      constrained: constrained,
      controlPoints: controlPoints,
      points: newPoints,
      label: label,
      text: text,
      fontFamily: fontFamily,
      mosaicMode: mosaicMode,
    );
  }

  /// Returns a copy with the given [newText] content.
  Annotation withText(String newText) {
    return Annotation(
      type: type,
      start: start,
      end: end,
      color: color,
      strokeWidth: strokeWidth,
      cornerRadius: cornerRadius,
      constrained: constrained,
      controlPoints: controlPoints,
      points: points,
      label: label,
      text: newText,
      fontFamily: fontFamily,
      mosaicMode: mosaicMode,
    );
  }

  /// Returns a copy with the given [mode] for mosaic annotations.
  Annotation withMosaicMode(MosaicMode mode) {
    return Annotation(
      type: type,
      start: start,
      end: end,
      color: color,
      strokeWidth: strokeWidth,
      cornerRadius: cornerRadius,
      constrained: constrained,
      controlPoints: controlPoints,
      points: points,
      label: label,
      text: text,
      fontFamily: fontFamily,
      mosaicMode: mode,
    );
  }

  /// Returns a copy with all positions shifted by [delta].
  Annotation translated(Offset delta) {
    return Annotation(
      type: type,
      start: start + delta,
      end: end + delta,
      color: color,
      strokeWidth: strokeWidth,
      cornerRadius: cornerRadius,
      constrained: constrained,
      controlPoints: [for (final cp in controlPoints) cp + delta],
      points: [for (final p in points) p + delta],
      label: label,
      text: text,
      fontFamily: fontFamily,
      mosaicMode: mosaicMode,
    );
  }
}
