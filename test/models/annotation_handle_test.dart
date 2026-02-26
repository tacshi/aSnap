import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:a_snap/models/annotation.dart';
import 'package:a_snap/models/annotation_handle.dart';

void main() {
  group('annotationHandles', () {
    test('rectangle returns 8 handles (4 corners + 4 edges)', () {
      const a = Annotation(
        type: ShapeType.rectangle,
        start: Offset(10, 10),
        end: Offset(110, 60),
        color: Color(0xFFFF0000),
        strokeWidth: 2,
      );
      final handles = annotationHandles(a);
      expect(handles.length, 8);
      expect(handles.map((h) => h.type).toSet(), {
        AnnHandleType.topLeft,
        AnnHandleType.topRight,
        AnnHandleType.bottomLeft,
        AnnHandleType.bottomRight,
        AnnHandleType.top,
        AnnHandleType.right,
        AnnHandleType.bottom,
        AnnHandleType.left,
      });
    });

    test('constrained rectangle handles use square rect', () {
      // Drag from (10,10) to (110,60) → raw rect is 100×50.
      // Constrained: side = min(100,50) = 50 → square (10,10)–(60,60).
      const a = Annotation(
        type: ShapeType.rectangle,
        start: Offset(10, 10),
        end: Offset(110, 60),
        color: Color(0xFFFF0000),
        strokeWidth: 2,
        constrained: true,
      );
      final handles = annotationHandles(a);
      expect(handles.length, 8);
      final tl = handles.firstWhere((h) => h.type == AnnHandleType.topLeft);
      final tr = handles.firstWhere((h) => h.type == AnnHandleType.topRight);
      final bl = handles.firstWhere((h) => h.type == AnnHandleType.bottomLeft);
      final br = handles.firstWhere((h) => h.type == AnnHandleType.bottomRight);
      expect(tl.position, const Offset(10, 10));
      expect(tr.position, const Offset(60, 10));
      expect(bl.position, const Offset(10, 60));
      expect(br.position, const Offset(60, 60));
      // Edge midpoints on the constrained square.
      final top = handles.firstWhere((h) => h.type == AnnHandleType.top);
      final right = handles.firstWhere((h) => h.type == AnnHandleType.right);
      final bottom = handles.firstWhere((h) => h.type == AnnHandleType.bottom);
      final left = handles.firstWhere((h) => h.type == AnnHandleType.left);
      expect(top.position, const Offset(35, 10));
      expect(right.position, const Offset(60, 35));
      expect(bottom.position, const Offset(35, 60));
      expect(left.position, const Offset(10, 35));
    });

    test('ellipse returns 4 edge midpoint handles', () {
      const a = Annotation(
        type: ShapeType.ellipse,
        start: Offset(10, 10),
        end: Offset(110, 60),
        color: Color(0xFFFF0000),
        strokeWidth: 2,
      );
      final handles = annotationHandles(a);
      expect(handles.length, 4);
      expect(handles.map((h) => h.type).toSet(), {
        AnnHandleType.top,
        AnnHandleType.right,
        AnnHandleType.bottom,
        AnnHandleType.left,
      });
    });

    test('constrained ellipse handles use square rect, not raw drag rect', () {
      // Drag from (10,10) to (110,60) → raw rect is 100×50.
      // Constrained: side = min(100,50) = 50 → square (10,10)–(60,60).
      const a = Annotation(
        type: ShapeType.ellipse,
        start: Offset(10, 10),
        end: Offset(110, 60),
        color: Color(0xFFFF0000),
        strokeWidth: 2,
        constrained: true,
      );
      final handles = annotationHandles(a);
      expect(handles.length, 4);
      // Constrained square: (10,10)–(60,60), center = (35,35).
      final top = handles.firstWhere((h) => h.type == AnnHandleType.top);
      final right = handles.firstWhere((h) => h.type == AnnHandleType.right);
      final bottom = handles.firstWhere((h) => h.type == AnnHandleType.bottom);
      final left = handles.firstWhere((h) => h.type == AnnHandleType.left);
      expect(top.position, const Offset(35, 10));
      expect(right.position, const Offset(60, 35));
      expect(bottom.position, const Offset(35, 60));
      expect(left.position, const Offset(10, 35));
    });

    test('line returns 2 endpoint handles', () {
      const a = Annotation(
        type: ShapeType.line,
        start: Offset(10, 10),
        end: Offset(110, 60),
        color: Color(0xFFFF0000),
        strokeWidth: 2,
      );
      final handles = annotationHandles(a);
      expect(handles.length, 2);
      expect(handles.map((h) => h.type).toSet(), {
        AnnHandleType.startPoint,
        AnnHandleType.endPoint,
      });
    });

    test('line with control points includes control point handles', () {
      final a = Annotation(
        type: ShapeType.line,
        start: const Offset(10, 10),
        end: const Offset(110, 60),
        color: const Color(0xFFFF0000),
        strokeWidth: 2,
        controlPoints: const [Offset(50, 0)],
      );
      final handles = annotationHandles(a);
      expect(handles.length, 3); // start + end + 1 control point
      expect(handles.any((h) => h.type == AnnHandleType.controlPoint), true);
    });

    test('mosaic returns 8 handles (4 corners + 4 edges)', () {
      const a = Annotation(
        type: ShapeType.mosaic,
        start: Offset(10, 10),
        end: Offset(110, 60),
        color: Color(0xFFFF0000),
        strokeWidth: 8,
      );
      final handles = annotationHandles(a);
      expect(handles.length, 8);
      expect(handles.map((h) => h.type).toSet(), {
        AnnHandleType.topLeft,
        AnnHandleType.topRight,
        AnnHandleType.bottomLeft,
        AnnHandleType.bottomRight,
        AnnHandleType.top,
        AnnHandleType.right,
        AnnHandleType.bottom,
        AnnHandleType.left,
      });
    });

    test('number stamp returns no handles', () {
      const a = Annotation(
        type: ShapeType.number,
        start: Offset(50, 50),
        end: Offset(50, 50),
        color: Color(0xFFFF0000),
        strokeWidth: 4,
        label: 1,
      );
      final handles = annotationHandles(a);
      expect(handles, isEmpty);
    });

    test('text returns no handles (size via slider, move via drag)', () {
      const a = Annotation(
        type: ShapeType.text,
        start: Offset(10, 10),
        end: Offset(100, 40),
        color: Color(0xFFFF0000),
        strokeWidth: 6,
        text: 'Hello',
      );
      final handles = annotationHandles(a);
      expect(handles, isEmpty);
    });
  });

  group('hitTestAnnotationHandle', () {
    test('returns handle when point is within radius', () {
      const a = Annotation(
        type: ShapeType.line,
        start: Offset(10, 10),
        end: Offset(110, 60),
        color: Color(0xFFFF0000),
        strokeWidth: 2,
      );
      final handles = annotationHandles(a);
      final hit = hitTestAnnotationHandle(const Offset(11, 11), handles);
      expect(hit, isNotNull);
      expect(hit!.type, AnnHandleType.startPoint);
    });

    test('returns null when point is far from handles', () {
      const a = Annotation(
        type: ShapeType.line,
        start: Offset(10, 10),
        end: Offset(110, 60),
        color: Color(0xFFFF0000),
        strokeWidth: 2,
      );
      final handles = annotationHandles(a);
      final hit = hitTestAnnotationHandle(const Offset(60, 30), handles);
      expect(hit, isNull);
    });
  });

  group('applyAnnotationHandleDrag', () {
    test('dragging rectangle topLeft corner updates start', () {
      const a = Annotation(
        type: ShapeType.rectangle,
        start: Offset(10, 10),
        end: Offset(110, 60),
        color: Color(0xFFFF0000),
        strokeWidth: 2,
      );
      final handle = AnnHandle(AnnHandleType.topLeft, const Offset(10, 10));
      final result = applyAnnotationHandleDrag(a, handle, const Offset(20, 20));
      final rect = result.boundingRect;
      // topLeft moved to (20,20), bottomRight stays at (110,60)
      expect(rect.left, 20);
      expect(rect.top, 20);
      expect(rect.right, 110);
      expect(rect.bottom, 60);
    });

    test('dragging ellipse top edge only changes top', () {
      const a = Annotation(
        type: ShapeType.ellipse,
        start: Offset(10, 10),
        end: Offset(110, 60),
        color: Color(0xFFFF0000),
        strokeWidth: 2,
      );
      final handle = AnnHandle(AnnHandleType.top, const Offset(60, 10));
      final result = applyAnnotationHandleDrag(a, handle, const Offset(60, 5));
      final rect = result.boundingRect;
      expect(rect.top, 5);
      expect(rect.bottom, 60);
      expect(rect.left, 10); // unchanged
      expect(rect.right, 110); // unchanged
    });

    test('dragging line startPoint updates start', () {
      const a = Annotation(
        type: ShapeType.line,
        start: Offset(10, 10),
        end: Offset(110, 60),
        color: Color(0xFFFF0000),
        strokeWidth: 2,
      );
      final handle = AnnHandle(AnnHandleType.startPoint, const Offset(10, 10));
      final result = applyAnnotationHandleDrag(a, handle, const Offset(20, 20));
      expect(result.start, const Offset(20, 20));
      expect(result.end, const Offset(110, 60)); // unchanged
    });

    test('dragging control point updates control point', () {
      final a = Annotation(
        type: ShapeType.line,
        start: const Offset(10, 10),
        end: const Offset(110, 60),
        color: const Color(0xFFFF0000),
        strokeWidth: 2,
        controlPoints: const [Offset(50, 0)],
      );
      final handle = AnnHandle(
        AnnHandleType.controlPoint,
        const Offset(50, 0),
        controlPointIndex: 0,
      );
      final result = applyAnnotationHandleDrag(a, handle, const Offset(50, 30));
      expect(result.controlPoints, [const Offset(50, 30)]);
    });

    // Text no longer has handles (removed in favor of move-drag and size slider).
  });
}
