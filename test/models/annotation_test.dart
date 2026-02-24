import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:a_snap/models/annotation.dart';

void main() {
  group('Annotation controlPoints', () {
    test('defaults to empty list', () {
      const a = Annotation(
        type: ShapeType.line,
        start: Offset(0, 0),
        end: Offset(100, 100),
        color: Color(0xFFFF0000),
        strokeWidth: 2,
      );
      expect(a.controlPoints, isEmpty);
    });

    test('withControlPoint updates existing control point', () {
      final a = Annotation(
        type: ShapeType.line,
        start: const Offset(0, 0),
        end: const Offset(100, 100),
        color: const Color(0xFFFF0000),
        strokeWidth: 2,
        controlPoints: const [Offset(50, 0)],
      );
      final b = a.withControlPoint(0, const Offset(50, 30));
      expect(b.controlPoints, [const Offset(50, 30)]);
      expect(a.controlPoints, [const Offset(50, 0)]); // immutable
    });

    test('addControlPoint appends a control point', () {
      const a = Annotation(
        type: ShapeType.arrow,
        start: Offset(0, 0),
        end: Offset(100, 100),
        color: Color(0xFFFF0000),
        strokeWidth: 2,
      );
      final b = a.addControlPoint(const Offset(50, 20));
      expect(b.controlPoints, [const Offset(50, 20)]);
    });

    test('addControlPoint caps at 2', () {
      final a = Annotation(
        type: ShapeType.line,
        start: const Offset(0, 0),
        end: const Offset(100, 100),
        color: const Color(0xFFFF0000),
        strokeWidth: 2,
        controlPoints: const [Offset(30, 10), Offset(70, 10)],
      );
      final b = a.addControlPoint(const Offset(50, 50));
      expect(b.controlPoints.length, 2); // unchanged
    });

    test('removeControlPoint removes by index', () {
      final a = Annotation(
        type: ShapeType.line,
        start: const Offset(0, 0),
        end: const Offset(100, 100),
        color: const Color(0xFFFF0000),
        strokeWidth: 2,
        controlPoints: const [Offset(30, 10), Offset(70, 10)],
      );
      final b = a.removeControlPoint(0);
      expect(b.controlPoints, [const Offset(70, 10)]);
    });

    test('copyWith preserves controlPoints', () {
      final a = Annotation(
        type: ShapeType.line,
        start: const Offset(0, 0),
        end: const Offset(100, 100),
        color: const Color(0xFFFF0000),
        strokeWidth: 2,
        controlPoints: const [Offset(50, 20)],
      );
      final b = a.withEnd(const Offset(200, 200));
      expect(b.controlPoints, [const Offset(50, 20)]);
    });
  });

  group('Freehand (pencil/marker)', () {
    test('isFreehand returns true for pencil', () {
      const a = Annotation(
        type: ShapeType.pencil,
        start: Offset(0, 0),
        end: Offset(100, 100),
        color: Color(0xFFFF0000),
        strokeWidth: 2,
      );
      expect(a.isFreehand, isTrue);
    });

    test('isFreehand returns true for marker', () {
      const a = Annotation(
        type: ShapeType.marker,
        start: Offset(0, 0),
        end: Offset(100, 100),
        color: Color(0xFFFF0000),
        strokeWidth: 2,
      );
      expect(a.isFreehand, isTrue);
    });

    test('isFreehand returns false for rectangle', () {
      const a = Annotation(
        type: ShapeType.rectangle,
        start: Offset(0, 0),
        end: Offset(100, 100),
        color: Color(0xFFFF0000),
        strokeWidth: 2,
      );
      expect(a.isFreehand, isFalse);
    });

    test('appendPoint adds point and updates end', () {
      const a = Annotation(
        type: ShapeType.pencil,
        start: Offset(0, 0),
        end: Offset(0, 0),
        color: Color(0xFFFF0000),
        strokeWidth: 2,
        points: [Offset(0, 0)],
      );
      final b = a.appendPoint(const Offset(10, 10));
      expect(b.points, [const Offset(0, 0), const Offset(10, 10)]);
      expect(b.end, const Offset(10, 10));
    });

    test('boundingRect computed from points for freehand', () {
      const a = Annotation(
        type: ShapeType.pencil,
        start: Offset(0, 0),
        end: Offset(100, 50),
        color: Color(0xFFFF0000),
        strokeWidth: 2,
        points: [Offset(10, 20), Offset(50, 5), Offset(100, 50), Offset(0, 30)],
      );
      final rect = a.boundingRect;
      expect(rect.left, 0);
      expect(rect.top, 5);
      expect(rect.right, 100);
      expect(rect.bottom, 50);
    });

    test('boundingRect falls back to start/end when points < 2', () {
      const a = Annotation(
        type: ShapeType.pencil,
        start: Offset(10, 20),
        end: Offset(50, 60),
        color: Color(0xFFFF0000),
        strokeWidth: 2,
        points: [Offset(10, 20)],
      );
      final rect = a.boundingRect;
      expect(rect, Rect.fromPoints(const Offset(10, 20), const Offset(50, 60)));
    });

    test('withPoints replaces all points', () {
      const a = Annotation(
        type: ShapeType.pencil,
        start: Offset(0, 0),
        end: Offset(100, 100),
        color: Color(0xFFFF0000),
        strokeWidth: 2,
        points: [Offset(0, 0), Offset(50, 50), Offset(100, 100)],
      );
      final b = a.withPoints(const [Offset(0, 0), Offset(100, 100)]);
      expect(b.points.length, 2);
    });

    test('copy methods preserve points', () {
      const a = Annotation(
        type: ShapeType.pencil,
        start: Offset(0, 0),
        end: Offset(100, 100),
        color: Color(0xFFFF0000),
        strokeWidth: 2,
        points: [Offset(0, 0), Offset(50, 50)],
      );
      expect(a.withEnd(const Offset(200, 200)).points, a.points);
      expect(a.withConstrained(true).points, a.points);
    });
  });
}
