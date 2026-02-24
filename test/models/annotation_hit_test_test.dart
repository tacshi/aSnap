import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:a_snap/models/annotation.dart';
import 'package:a_snap/models/annotation_hit_test.dart';

void main() {
  group('hitTestAnnotations', () {
    test('returns index of line near point', () {
      final annotations = [
        const Annotation(
          type: ShapeType.line,
          start: Offset(0, 0),
          end: Offset(100, 0),
          color: Color(0xFFFF0000),
          strokeWidth: 2,
        ),
      ];
      // Point 3px away from the line (within default threshold)
      final idx = hitTestAnnotations(const Offset(50, 3), annotations);
      expect(idx, 0);
    });

    test('returns null when point is far from all shapes', () {
      final annotations = [
        const Annotation(
          type: ShapeType.line,
          start: Offset(0, 0),
          end: Offset(100, 0),
          color: Color(0xFFFF0000),
          strokeWidth: 2,
        ),
      ];
      final idx = hitTestAnnotations(const Offset(50, 30), annotations);
      expect(idx, isNull);
    });

    test('returns topmost (last) shape when overlapping', () {
      final annotations = [
        const Annotation(
          type: ShapeType.rectangle,
          start: Offset(0, 0),
          end: Offset(100, 100),
          color: Color(0xFFFF0000),
          strokeWidth: 2,
        ),
        const Annotation(
          type: ShapeType.rectangle,
          start: Offset(10, 10),
          end: Offset(90, 90),
          color: Color(0xFF00FF00),
          strokeWidth: 2,
        ),
      ];
      // On the edge of the inner rect — hits both, returns last (topmost)
      final idx = hitTestAnnotations(const Offset(10, 50), annotations);
      expect(idx, 1);
    });

    test('hits rectangle edge', () {
      final annotations = [
        const Annotation(
          type: ShapeType.rectangle,
          start: Offset(10, 10),
          end: Offset(100, 100),
          color: Color(0xFFFF0000),
          strokeWidth: 2,
        ),
      ];
      // On left edge
      final idx = hitTestAnnotations(const Offset(10, 50), annotations);
      expect(idx, 0);
    });

    test('misses rectangle interior', () {
      final annotations = [
        const Annotation(
          type: ShapeType.rectangle,
          start: Offset(10, 10),
          end: Offset(100, 100),
          color: Color(0xFFFF0000),
          strokeWidth: 2,
        ),
      ];
      final idx = hitTestAnnotations(const Offset(55, 55), annotations);
      expect(idx, isNull);
    });

    test('hits ellipse perimeter', () {
      final annotations = [
        const Annotation(
          type: ShapeType.ellipse,
          start: Offset(0, 0),
          end: Offset(100, 100),
          color: Color(0xFFFF0000),
          strokeWidth: 2,
        ),
      ];
      // Top of circle (center=50,50 radius=50): point at (50, 0)
      final idx = hitTestAnnotations(const Offset(50, 0), annotations);
      expect(idx, 0);
    });
  });

  group('Bézier hit test', () {
    test('hits quadratic Bézier between sample points on long curve', () {
      // A long line (1000px) with a control point that makes it curve.
      // With point-only sampling, clicks between sample points would miss.
      final annotations = [
        const Annotation(
          type: ShapeType.line,
          start: Offset(0, 0),
          end: Offset(1000, 0),
          color: Color(0xFFFF0000),
          strokeWidth: 2,
          controlPoints: [Offset(500, 50)],
        ),
      ];
      // The quadratic Bézier at t=0.5 is: (1-0.5)²·(0,0) + 2·0.5·0.5·(500,50) + 0.5²·(1000,0)
      // = 0.25·(0,0) + 0.5·(500,50) + 0.25·(1000,0)
      // = (0,0) + (250,25) + (250,0) = (500, 25)
      // A point ON the curve at approximately the midpoint should hit.
      final idx = hitTestAnnotations(const Offset(500, 25), annotations);
      expect(idx, 0);
    });

    test('hits cubic Bézier between sample points', () {
      final annotations = [
        const Annotation(
          type: ShapeType.line,
          start: Offset(0, 0),
          end: Offset(1000, 0),
          color: Color(0xFFFF0000),
          strokeWidth: 2,
          controlPoints: [Offset(333, 100), Offset(666, -100)],
        ),
      ];
      // Point near the curve midpoint should hit with segment-based distance.
      // Cubic at t=0.5: 0.125·(0,0) + 0.375·(333,100) + 0.375·(666,-100) + 0.125·(1000,0)
      // = (0,0) + (124.875, 37.5) + (249.75, -37.5) + (125, 0)
      // = (499.625, 0)
      final idx = hitTestAnnotations(const Offset(500, 0), annotations);
      expect(idx, 0);
    });

    test('misses Bézier when point is far from curve', () {
      final annotations = [
        const Annotation(
          type: ShapeType.line,
          start: Offset(0, 0),
          end: Offset(1000, 0),
          color: Color(0xFFFF0000),
          strokeWidth: 2,
          controlPoints: [Offset(500, 50)],
        ),
      ];
      // Point 100px from the curve should miss.
      final idx = hitTestAnnotations(const Offset(500, 130), annotations);
      expect(idx, isNull);
    });
  });

  group('distanceToLineSegment', () {
    test('point perpendicular to segment', () {
      final d = distanceToLineSegment(
        const Offset(50, 10),
        const Offset(0, 0),
        const Offset(100, 0),
      );
      expect(d, closeTo(10, 0.01));
    });

    test('point beyond segment end', () {
      final d = distanceToLineSegment(
        const Offset(110, 0),
        const Offset(0, 0),
        const Offset(100, 0),
      );
      expect(d, closeTo(10, 0.01));
    });
  });
}
