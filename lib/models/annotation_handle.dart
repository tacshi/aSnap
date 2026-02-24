import 'dart:ui';

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

/// Returns all handles for the given annotation.
List<AnnHandle> annotationHandles(Annotation annotation) {
  final rect = Rect.fromPoints(annotation.start, annotation.end);
  switch (annotation.type) {
    case ShapeType.rectangle:
      return [
        AnnHandle(AnnHandleType.topLeft, rect.topLeft),
        AnnHandle(AnnHandleType.topRight, rect.topRight),
        AnnHandle(AnnHandleType.bottomLeft, rect.bottomLeft),
        AnnHandle(AnnHandleType.bottomRight, rect.bottomRight),
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
    case ShapeType.pencil:
    case ShapeType.marker:
      // Freehand shapes have no resize handles.
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
  );
}
