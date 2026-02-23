import 'package:a_snap/models/selection_handle.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const selection = Rect.fromLTWH(100, 100, 200, 150);
  const screenBounds = Size(1920, 1080);

  group('handlePosition', () {
    test('returns correct positions for all 8 handles', () {
      expect(
        handlePosition(SelectionHandle.topLeft, selection),
        const Offset(100, 100),
      );
      expect(
        handlePosition(SelectionHandle.topCenter, selection),
        const Offset(200, 100),
      );
      expect(
        handlePosition(SelectionHandle.topRight, selection),
        const Offset(300, 100),
      );
      expect(
        handlePosition(SelectionHandle.middleLeft, selection),
        const Offset(100, 175),
      );
      expect(
        handlePosition(SelectionHandle.middleRight, selection),
        const Offset(300, 175),
      );
      expect(
        handlePosition(SelectionHandle.bottomLeft, selection),
        const Offset(100, 250),
      );
      expect(
        handlePosition(SelectionHandle.bottomCenter, selection),
        const Offset(200, 250),
      );
      expect(
        handlePosition(SelectionHandle.bottomRight, selection),
        const Offset(300, 250),
      );
    });
  });

  group('hitTestHandle', () {
    test('returns handle when point is within hit radius', () {
      expect(
        hitTestHandle(const Offset(102, 102), selection),
        SelectionHandle.topLeft,
      );
      expect(
        hitTestHandle(const Offset(298, 248), selection),
        SelectionHandle.bottomRight,
      );
    });

    test('returns null when point is outside all handles', () {
      expect(hitTestHandle(const Offset(200, 175), selection), isNull);
    });

    test('prioritizes corners over edges at small selections', () {
      // Small selection where corner and edge handles overlap.
      const small = Rect.fromLTWH(100, 100, 12, 12);
      // Point near top-left corner and also near topCenter.
      final topLeftPos = handlePosition(SelectionHandle.topLeft, small);
      expect(hitTestHandle(topLeftPos, small), SelectionHandle.topLeft);
    });

    test('respects custom hit radius', () {
      // Outside default radius of 8, but within radius of 20.
      expect(
        hitTestHandle(const Offset(115, 115), selection, hitRadius: 8),
        isNull,
      );
      expect(
        hitTestHandle(const Offset(115, 115), selection, hitRadius: 22),
        SelectionHandle.topLeft,
      );
    });
  });

  group('cursorForHandle', () {
    test('returns correct resize cursors', () {
      expect(
        cursorForHandle(SelectionHandle.topLeft),
        SystemMouseCursors.resizeUpLeft,
      );
      expect(
        cursorForHandle(SelectionHandle.topCenter),
        SystemMouseCursors.resizeUp,
      );
      expect(
        cursorForHandle(SelectionHandle.topRight),
        SystemMouseCursors.resizeUpRight,
      );
      expect(
        cursorForHandle(SelectionHandle.middleLeft),
        SystemMouseCursors.resizeLeft,
      );
      expect(
        cursorForHandle(SelectionHandle.middleRight),
        SystemMouseCursors.resizeRight,
      );
      expect(
        cursorForHandle(SelectionHandle.bottomLeft),
        SystemMouseCursors.resizeDownLeft,
      );
      expect(
        cursorForHandle(SelectionHandle.bottomCenter),
        SystemMouseCursors.resizeDown,
      );
      expect(
        cursorForHandle(SelectionHandle.bottomRight),
        SystemMouseCursors.resizeDownRight,
      );
    });
  });

  group('applyResize', () {
    test('adjusts bottom-right corner correctly', () {
      final result = applyResize(
        SelectionHandle.bottomRight,
        selection,
        const Offset(50, 30),
        screenBounds,
      );
      expect(result, const Rect.fromLTRB(100, 100, 350, 280));
    });

    test('adjusts top-left corner correctly', () {
      final result = applyResize(
        SelectionHandle.topLeft,
        selection,
        const Offset(-20, -10),
        screenBounds,
      );
      expect(result, const Rect.fromLTRB(80, 90, 300, 250));
    });

    test('adjusts edge handle (topCenter) only vertically', () {
      final result = applyResize(
        SelectionHandle.topCenter,
        selection,
        const Offset(50, -20), // dx should be ignored
        screenBounds,
      );
      expect(result, const Rect.fromLTRB(100, 80, 300, 250));
    });

    test('adjusts edge handle (middleRight) only horizontally', () {
      final result = applyResize(
        SelectionHandle.middleRight,
        selection,
        const Offset(30, 50), // dy should be ignored
        screenBounds,
      );
      expect(result, const Rect.fromLTRB(100, 100, 330, 250));
    });

    test('enforces minimum size when shrinking from left', () {
      // Drag left edge past right edge.
      final result = applyResize(
        SelectionHandle.middleLeft,
        selection,
        const Offset(250, 0), // Would make width negative
        screenBounds,
      );
      expect(result.width, 10);
      expect(result.left, selection.right - 10);
    });

    test('enforces minimum size when shrinking from right', () {
      final result = applyResize(
        SelectionHandle.middleRight,
        selection,
        const Offset(-250, 0),
        screenBounds,
      );
      expect(result.width, 10);
      expect(result.right, selection.left + 10);
    });

    test('enforces minimum size when shrinking from top', () {
      final result = applyResize(
        SelectionHandle.topCenter,
        selection,
        const Offset(0, 200), // Would push top past bottom
        screenBounds,
      );
      expect(result.height, 10);
      expect(result.top, selection.bottom - 10);
    });

    test('enforces minimum size when shrinking from bottom', () {
      final result = applyResize(
        SelectionHandle.bottomCenter,
        selection,
        const Offset(0, -200),
        screenBounds,
      );
      expect(result.height, 10);
      expect(result.bottom, selection.top + 10);
    });

    test('clamps to screen bounds', () {
      final result = applyResize(
        SelectionHandle.topLeft,
        selection,
        const Offset(-200, -200),
        screenBounds,
      );
      expect(result.left, 0);
      expect(result.top, 0);
    });

    test('clamps right edge to screen width', () {
      final result = applyResize(
        SelectionHandle.bottomRight,
        selection,
        const Offset(2000, 0),
        screenBounds,
      );
      expect(result.right, screenBounds.width);
    });

    test('clamps bottom edge to screen height', () {
      final result = applyResize(
        SelectionHandle.bottomRight,
        selection,
        const Offset(0, 2000),
        screenBounds,
      );
      expect(result.bottom, screenBounds.height);
    });

    test('never produces negative dimensions', () {
      // Test all handles with extreme deltas.
      for (final handle in SelectionHandle.values) {
        final result = applyResize(
          handle,
          selection,
          const Offset(-500, -500),
          screenBounds,
        );
        expect(result.width, greaterThanOrEqualTo(10));
        expect(result.height, greaterThanOrEqualTo(10));
      }
    });
  });

  group('clampToScreen', () {
    test('clamps rect within screen bounds', () {
      const rect = Rect.fromLTWH(-10, -20, 200, 150);
      final result = clampToScreen(rect, screenBounds);
      expect(result.left, 0);
      expect(result.top, 0);
      expect(result.width, 200);
      expect(result.height, 150);
    });

    test('clamps rect overflowing right/bottom', () {
      const rect = Rect.fromLTWH(1800, 1000, 200, 150);
      final result = clampToScreen(rect, screenBounds);
      expect(result.right, screenBounds.width);
      expect(result.bottom, screenBounds.height);
      expect(result.width, 200);
      expect(result.height, 150);
    });

    test('does not change already-contained rect', () {
      final result = clampToScreen(selection, screenBounds);
      expect(result, selection);
    });
  });
}
