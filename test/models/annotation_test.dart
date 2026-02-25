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

  group('Number stamp', () {
    test('isStamp returns true for number type', () {
      const a = Annotation(
        type: ShapeType.number,
        start: Offset(50, 50),
        end: Offset(50, 50),
        color: Color(0xFFFF0000),
        strokeWidth: 4,
        label: 1,
      );
      expect(a.isStamp, isTrue);
      expect(a.isFreehand, isFalse);
    });

    test('isStamp returns false for other types', () {
      const a = Annotation(
        type: ShapeType.rectangle,
        start: Offset(0, 0),
        end: Offset(100, 100),
        color: Color(0xFFFF0000),
        strokeWidth: 2,
      );
      expect(a.isStamp, isFalse);
    });

    test('stampRadius is strokeWidth * 4', () {
      const a = Annotation(
        type: ShapeType.number,
        start: Offset(50, 50),
        end: Offset(50, 50),
        color: Color(0xFFFF0000),
        strokeWidth: 5,
        label: 1,
      );
      expect(a.stampRadius, 20);
    });

    test('boundingRect is circle around start for stamps', () {
      const a = Annotation(
        type: ShapeType.number,
        start: Offset(100, 100),
        end: Offset(100, 100),
        color: Color(0xFFFF0000),
        strokeWidth: 4,
        label: 1,
      );
      final rect = a.boundingRect;
      // radius = 4 * 4 = 16
      expect(rect.left, 84);
      expect(rect.top, 84);
      expect(rect.right, 116);
      expect(rect.bottom, 116);
    });

    test('label is preserved through copy methods', () {
      const a = Annotation(
        type: ShapeType.number,
        start: Offset(50, 50),
        end: Offset(50, 50),
        color: Color(0xFFFF0000),
        strokeWidth: 4,
        label: 3,
      );
      expect(a.withEnd(const Offset(60, 60)).label, 3);
      expect(a.withConstrained(true).label, 3);
    });

    test('label defaults to null', () {
      const a = Annotation(
        type: ShapeType.rectangle,
        start: Offset(0, 0),
        end: Offset(100, 100),
        color: Color(0xFFFF0000),
        strokeWidth: 2,
      );
      expect(a.label, isNull);
    });
  });

  group('Text annotation', () {
    test('isText returns true for text type', () {
      const a = Annotation(
        type: ShapeType.text,
        start: Offset(10, 10),
        end: Offset(100, 40),
        color: Color(0xFFFF0000),
        strokeWidth: 6,
        text: 'Hello',
      );
      expect(a.isText, isTrue);
      expect(a.isFreehand, isFalse);
      expect(a.isStamp, isFalse);
    });

    test('isText returns false for other types', () {
      const a = Annotation(
        type: ShapeType.rectangle,
        start: Offset(0, 0),
        end: Offset(100, 100),
        color: Color(0xFFFF0000),
        strokeWidth: 2,
      );
      expect(a.isText, isFalse);
    });

    test('fontSize is strokeWidth * 4', () {
      const a = Annotation(
        type: ShapeType.text,
        start: Offset(10, 10),
        end: Offset(100, 40),
        color: Color(0xFFFF0000),
        strokeWidth: 5,
        text: 'Hello',
      );
      expect(a.fontSize, 20);
    });

    test('boundingRect uses start/end for text', () {
      const a = Annotation(
        type: ShapeType.text,
        start: Offset(10, 20),
        end: Offset(100, 50),
        color: Color(0xFFFF0000),
        strokeWidth: 6,
        text: 'Hello',
      );
      final rect = a.boundingRect;
      expect(rect.left, 10);
      expect(rect.top, 20);
      expect(rect.right, 100);
      expect(rect.bottom, 50);
    });

    test('text and fontFamily preserved through copy methods', () {
      const a = Annotation(
        type: ShapeType.text,
        start: Offset(10, 10),
        end: Offset(100, 40),
        color: Color(0xFFFF0000),
        strokeWidth: 6,
        text: 'Hello',
        fontFamily: 'Georgia',
      );
      expect(a.withEnd(const Offset(200, 80)).text, 'Hello');
      expect(a.withEnd(const Offset(200, 80)).fontFamily, 'Georgia');
      expect(a.withConstrained(true).text, 'Hello');
      expect(a.withConstrained(true).fontFamily, 'Georgia');
    });

    test('withText creates copy with new text', () {
      const a = Annotation(
        type: ShapeType.text,
        start: Offset(10, 10),
        end: Offset(100, 40),
        color: Color(0xFFFF0000),
        strokeWidth: 6,
        text: 'Hello',
        fontFamily: 'Georgia',
      );
      final b = a.withText('World');
      expect(b.text, 'World');
      expect(b.fontFamily, 'Georgia'); // preserved
      expect(b.color, a.color); // preserved
      expect(a.text, 'Hello'); // immutable
    });

    test('text defaults to null', () {
      const a = Annotation(
        type: ShapeType.rectangle,
        start: Offset(0, 0),
        end: Offset(100, 100),
        color: Color(0xFFFF0000),
        strokeWidth: 2,
      );
      expect(a.text, isNull);
      expect(a.fontFamily, isNull);
    });
  });

  group('Mosaic annotation', () {
    test('isMosaic returns true for mosaic type', () {
      const a = Annotation(
        type: ShapeType.mosaic,
        start: Offset(0, 0),
        end: Offset(100, 100),
        color: Color(0xFFFF0000),
        strokeWidth: 2,
      );
      expect(a.isMosaic, isTrue);
      expect(a.isFreehand, isFalse);
      expect(a.isStamp, isFalse);
      expect(a.isText, isFalse);
    });

    test('mosaicMode defaults to MosaicMode.pixelate', () {
      const a = Annotation(
        type: ShapeType.mosaic,
        start: Offset(0, 0),
        end: Offset(100, 100),
        color: Color(0xFFFF0000),
        strokeWidth: 2,
      );
      expect(a.mosaicMode, MosaicMode.pixelate);
    });

    test('withMosaicMode returns copy with updated mode', () {
      const a = Annotation(
        type: ShapeType.mosaic,
        start: Offset(0, 0),
        end: Offset(100, 100),
        color: Color(0xFFFF0000),
        strokeWidth: 2,
      );
      final b = a.withMosaicMode(MosaicMode.blur);
      expect(b.mosaicMode, MosaicMode.blur);
      expect(b.type, ShapeType.mosaic);
      expect(b.start, a.start);
      expect(b.end, a.end);
      expect(b.color, a.color);
      expect(b.strokeWidth, a.strokeWidth);
      // Original unchanged (immutable).
      expect(a.mosaicMode, MosaicMode.pixelate);

      final c = a.withMosaicMode(MosaicMode.solidColor);
      expect(c.mosaicMode, MosaicMode.solidColor);
    });

    test('translated preserves mosaicMode', () {
      const a = Annotation(
        type: ShapeType.mosaic,
        start: Offset(10, 20),
        end: Offset(100, 80),
        color: Color(0xFFFF0000),
        strokeWidth: 2,
        mosaicMode: MosaicMode.blur,
      );
      final b = a.translated(const Offset(5, -5));
      expect(b.mosaicMode, MosaicMode.blur);
      expect(b.start, const Offset(15, 15));
      expect(b.end, const Offset(105, 75));
    });

    test('isMosaic returns false for other types', () {
      const a = Annotation(
        type: ShapeType.rectangle,
        start: Offset(0, 0),
        end: Offset(100, 100),
        color: Color(0xFFFF0000),
        strokeWidth: 2,
      );
      expect(a.isMosaic, isFalse);
    });

    test('mosaicMode preserved through copy methods', () {
      const a = Annotation(
        type: ShapeType.mosaic,
        start: Offset(0, 0),
        end: Offset(100, 100),
        color: Color(0xFFFF0000),
        strokeWidth: 2,
        mosaicMode: MosaicMode.blur,
      );
      expect(a.withEnd(const Offset(200, 200)).mosaicMode, MosaicMode.blur);
      expect(a.withConstrained(true).mosaicMode, MosaicMode.blur);
      expect(a.withText('test').mosaicMode, MosaicMode.blur);
      expect(a.withPoints(const [Offset(1, 1)]).mosaicMode, MosaicMode.blur);
    });

    test('boundingRect uses start/end for mosaic', () {
      const a = Annotation(
        type: ShapeType.mosaic,
        start: Offset(10, 20),
        end: Offset(100, 80),
        color: Color(0xFFFF0000),
        strokeWidth: 2,
      );
      final rect = a.boundingRect;
      expect(rect.left, 10);
      expect(rect.top, 20);
      expect(rect.right, 100);
      expect(rect.bottom, 80);
    });
  });

  group('translated', () {
    test('shifts start and end by delta for text annotation', () {
      const a = Annotation(
        type: ShapeType.text,
        start: Offset(10, 20),
        end: Offset(100, 50),
        color: Color(0xFFFF0000),
        strokeWidth: 6,
        text: 'Hello',
        fontFamily: 'Georgia',
      );
      final b = a.translated(const Offset(30, -10));
      expect(b.start, const Offset(40, 10));
      expect(b.end, const Offset(130, 40));
      expect(b.text, 'Hello');
      expect(b.fontFamily, 'Georgia');
      expect(b.color, a.color);
      expect(b.strokeWidth, a.strokeWidth);
      // Original unchanged (immutable).
      expect(a.start, const Offset(10, 20));
    });

    test('shifts controlPoints and points', () {
      final a = Annotation(
        type: ShapeType.line,
        start: const Offset(0, 0),
        end: const Offset(100, 100),
        color: const Color(0xFFFF0000),
        strokeWidth: 2,
        controlPoints: const [Offset(50, 0)],
        points: const [Offset(10, 10), Offset(20, 20)],
      );
      final b = a.translated(const Offset(10, 20));
      expect(b.start, const Offset(10, 20));
      expect(b.end, const Offset(110, 120));
      expect(b.controlPoints, [const Offset(60, 20)]);
      expect(b.points, [const Offset(20, 30), const Offset(30, 40)]);
    });
  });
}
