import 'dart:math' show min;

import 'package:flutter/services.dart';

import 'annotation.dart';

/// Handle types for annotation shape manipulation.
enum AnnHandleType {
  // Rectangle corners
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,
  // Ellipse edge midpoints
  top,
  right,
  bottom,
  left,
  // Line/arrow endpoints
  startPoint,
  endPoint,
  // Bézier control points
  controlPoint,
}

/// A positioned handle on an annotation.
class AnnHandle {
  final AnnHandleType type;
  final Offset position;

  /// Index into [Annotation.controlPoints] (only for [AnnHandleType.controlPoint]).
  final int? controlPointIndex;

  const AnnHandle(this.type, this.position, {this.controlPointIndex});
}

/// Compute the display rect for an annotation, constraining to a square
/// when [Annotation.constrained] is true (Shift held during drawing).
Rect _constrainedRect(Annotation annotation) {
  final raw = Rect.fromPoints(annotation.start, annotation.end);
  if (!annotation.constrained) return raw;
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

/// Returns all handles for the given annotation.
List<AnnHandle> annotationHandles(Annotation annotation) {
  final rect = _constrainedRect(annotation);
  switch (annotation.type) {
    case ShapeType.rectangle:
      return [
        AnnHandle(AnnHandleType.topLeft, rect.topLeft),
        AnnHandle(AnnHandleType.topRight, rect.topRight),
        AnnHandle(AnnHandleType.bottomLeft, rect.bottomLeft),
        AnnHandle(AnnHandleType.bottomRight, rect.bottomRight),
        AnnHandle(AnnHandleType.top, Offset(rect.center.dx, rect.top)),
        AnnHandle(AnnHandleType.right, Offset(rect.right, rect.center.dy)),
        AnnHandle(AnnHandleType.bottom, Offset(rect.center.dx, rect.bottom)),
        AnnHandle(AnnHandleType.left, Offset(rect.left, rect.center.dy)),
      ];
    case ShapeType.ellipse:
      return [
        AnnHandle(AnnHandleType.top, Offset(rect.center.dx, rect.top)),
        AnnHandle(AnnHandleType.right, Offset(rect.right, rect.center.dy)),
        AnnHandle(AnnHandleType.bottom, Offset(rect.center.dx, rect.bottom)),
        AnnHandle(AnnHandleType.left, Offset(rect.left, rect.center.dy)),
      ];
    case ShapeType.line:
    case ShapeType.arrow:
      return [
        AnnHandle(AnnHandleType.startPoint, annotation.start),
        AnnHandle(AnnHandleType.endPoint, annotation.end),
        for (int i = 0; i < annotation.controlPoints.length; i++)
          AnnHandle(
            AnnHandleType.controlPoint,
            annotation.controlPoints[i],
            controlPointIndex: i,
          ),
      ];
    case ShapeType.mosaic:
      return [
        AnnHandle(AnnHandleType.topLeft, rect.topLeft),
        AnnHandle(AnnHandleType.topRight, rect.topRight),
        AnnHandle(AnnHandleType.bottomLeft, rect.bottomLeft),
        AnnHandle(AnnHandleType.bottomRight, rect.bottomRight),
        AnnHandle(AnnHandleType.top, Offset(rect.center.dx, rect.top)),
        AnnHandle(AnnHandleType.right, Offset(rect.right, rect.center.dy)),
        AnnHandle(AnnHandleType.bottom, Offset(rect.center.dx, rect.bottom)),
        AnnHandle(AnnHandleType.left, Offset(rect.left, rect.center.dy)),
      ];
    case ShapeType.text:
    case ShapeType.pencil:
    case ShapeType.marker:
    case ShapeType.number:
      // Text, freehand shapes, and stamps have no resize handles.
      // Text size is controlled via the stroke-width slider.
      return [];
  }
}

/// Hit-tests [point] against [handles].
///
/// Returns nearest hit within [hitRadius], or null.
AnnHandle? hitTestAnnotationHandle(
  Offset point,
  List<AnnHandle> handles, {
  double hitRadius = 8,
}) {
  AnnHandle? best;
  double bestDist = hitRadius;
  for (final h in handles) {
    final d = (point - h.position).distance;
    if (d <= bestDist) {
      bestDist = d;
      best = h;
    }
  }
  return best;
}

/// Returns a new annotation with the handle dragged to [newPosition].
Annotation applyAnnotationHandleDrag(
  Annotation annotation,
  AnnHandle handle,
  Offset newPosition,
) {
  switch (handle.type) {
    // Rectangle corners: dragged corner moves, opposite stays pinned.
    case AnnHandleType.topLeft:
      final pinned = Rect.fromPoints(annotation.start, annotation.end);
      return _withStartEnd(
        annotation,
        Offset(newPosition.dx, newPosition.dy),
        pinned.bottomRight,
      );
    case AnnHandleType.topRight:
      final pinned = Rect.fromPoints(annotation.start, annotation.end);
      return _withStartEnd(
        annotation,
        Offset(pinned.left, newPosition.dy),
        Offset(newPosition.dx, pinned.bottom),
      );
    case AnnHandleType.bottomLeft:
      final pinned = Rect.fromPoints(annotation.start, annotation.end);
      return _withStartEnd(
        annotation,
        Offset(newPosition.dx, pinned.top),
        Offset(pinned.right, newPosition.dy),
      );
    case AnnHandleType.bottomRight:
      final pinned = Rect.fromPoints(annotation.start, annotation.end);
      return _withStartEnd(
        annotation,
        pinned.topLeft,
        Offset(newPosition.dx, newPosition.dy),
      );

    // Ellipse edges: only change the relevant axis.
    case AnnHandleType.top:
      final rect = Rect.fromPoints(annotation.start, annotation.end);
      return _withStartEnd(
        annotation,
        Offset(rect.left, newPosition.dy),
        rect.bottomRight,
      );
    case AnnHandleType.bottom:
      final rect = Rect.fromPoints(annotation.start, annotation.end);
      return _withStartEnd(
        annotation,
        rect.topLeft,
        Offset(rect.right, newPosition.dy),
      );
    case AnnHandleType.left:
      final rect = Rect.fromPoints(annotation.start, annotation.end);
      return _withStartEnd(
        annotation,
        Offset(newPosition.dx, rect.top),
        rect.bottomRight,
      );
    case AnnHandleType.right:
      final rect = Rect.fromPoints(annotation.start, annotation.end);
      return _withStartEnd(
        annotation,
        rect.topLeft,
        Offset(newPosition.dx, rect.bottom),
      );

    // Line/arrow endpoints.
    case AnnHandleType.startPoint:
      return _withStartEnd(annotation, newPosition, annotation.end);
    case AnnHandleType.endPoint:
      return _withStartEnd(annotation, annotation.start, newPosition);

    // Bézier control point.
    case AnnHandleType.controlPoint:
      return annotation.withControlPoint(
        handle.controlPointIndex!,
        newPosition,
      );
  }
}

/// Whether [type] is one of the four corner handles.
bool isCornerAnnotationHandle(AnnHandleType type) => switch (type) {
  AnnHandleType.topLeft ||
  AnnHandleType.topRight ||
  AnnHandleType.bottomLeft ||
  AnnHandleType.bottomRight => true,
  _ => false,
};

/// Returns the appropriate resize cursor for an annotation [handle].
///
/// Corner handles return `resizeUpLeft`/etc. but note that on macOS these
/// silently fall back to the arrow cursor — use [nativeDiagonalCursorType]
/// with the platform channel for diagonal cursors on macOS.
MouseCursor cursorForAnnotationHandle(AnnHandleType type) => switch (type) {
  AnnHandleType.topLeft => SystemMouseCursors.resizeUpLeft,
  AnnHandleType.topRight => SystemMouseCursors.resizeUpRight,
  AnnHandleType.bottomLeft => SystemMouseCursors.resizeDownLeft,
  AnnHandleType.bottomRight => SystemMouseCursors.resizeDownRight,
  AnnHandleType.top => SystemMouseCursors.resizeUp,
  AnnHandleType.bottom => SystemMouseCursors.resizeDown,
  AnnHandleType.left => SystemMouseCursors.resizeLeft,
  AnnHandleType.right => SystemMouseCursors.resizeRight,
  AnnHandleType.startPoint || AnnHandleType.endPoint => SystemMouseCursors.grab,
  AnnHandleType.controlPoint => SystemMouseCursors.grab,
};

/// Returns the native macOS diagonal cursor type string ('nwse' or 'nesw')
/// for corner handles, or null for non-corner handles.
String? nativeDiagonalCursorType(AnnHandleType type) => switch (type) {
  AnnHandleType.topLeft || AnnHandleType.bottomRight => 'nwse',
  AnnHandleType.topRight || AnnHandleType.bottomLeft => 'nesw',
  _ => null,
};

Annotation _withStartEnd(Annotation a, Offset start, Offset end) {
  return Annotation(
    type: a.type,
    start: start,
    end: end,
    color: a.color,
    strokeWidth: a.strokeWidth,
    cornerRadius: a.cornerRadius,
    constrained: a.constrained,
    controlPoints: a.controlPoints,
    points: a.points,
    label: a.label,
    text: a.text,
    fontFamily: a.fontFamily,
    mosaicMode: a.mosaicMode,
  );
}
