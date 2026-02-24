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
}
