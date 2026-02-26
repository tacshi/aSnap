import 'dart:ui';

import 'package:a_snap/utils/toolbar_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('computeToolbarRect', () {
    test('places toolbar below anchor when there is room', () {
      final rect = computeToolbarRect(
        anchorRect: const Rect.fromLTWH(400, 200, 300, 150),
        screenSize: const Size(1920, 1080),
      );

      // Should be below the anchor with kToolbarGap spacing.
      expect(rect.top, 200 + 150 + kToolbarGap);
      expect(rect.width, kToolbarSize.width);
      expect(rect.height, kToolbarSize.height);
    });

    test('places toolbar above anchor when no room below', () {
      final rect = computeToolbarRect(
        anchorRect: const Rect.fromLTWH(400, 900, 300, 150),
        screenSize: const Size(1920, 1080),
      );

      // No room below (900+150+8+44 > 1080), should be above.
      expect(rect.bottom, 900 - kToolbarGap);
    });

    test('places toolbar inside anchor when no room above or below', () {
      // Anchor fills almost the entire screen vertically.
      final rect = computeToolbarRect(
        anchorRect: const Rect.fromLTWH(400, 0, 300, 1080),
        screenSize: const Size(1920, 1080),
      );

      // Neither above nor below fits — placed inside the anchor.
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.bottom, lessThanOrEqualTo(1080));
    });

    test('clamps horizontally to screen bounds', () {
      // Anchor is far right — toolbar should not overflow.
      final rect = computeToolbarRect(
        anchorRect: const Rect.fromLTWH(1800, 200, 100, 100),
        screenSize: const Size(1920, 1080),
      );

      expect(rect.right, lessThanOrEqualTo(1920));
      expect(rect.left, greaterThanOrEqualTo(0));
    });

    test('does not throw when screen is narrower than toolbar', () {
      final rect = computeToolbarRect(
        anchorRect: const Rect.fromLTWH(100, 50, 200, 120),
        screenSize: const Size(400, 300),
      );

      expect(rect.left, 0.0);
      expect(rect.width, kToolbarSize.width);
      expect(rect.height, kToolbarSize.height);
    });
  });

  group('computeToolbarRectBelowWindow', () {
    test('places toolbar below window with gap', () {
      final rect = computeToolbarRectBelowWindow(
        windowRect: const Rect.fromLTWH(300, 200, 400, 300),
        screenRect: const Rect.fromLTWH(0, 0, 1920, 1080),
      );

      expect(rect.top, 200 + 300 + kToolbarGap);
    });

    test('clamps to screen bottom when no room below', () {
      final rect = computeToolbarRectBelowWindow(
        windowRect: const Rect.fromLTWH(300, 900, 400, 150),
        screenRect: const Rect.fromLTWH(0, 0, 1920, 1080),
      );

      // Window bottom is 1050, gap puts toolbar at 1058, which overflows.
      // Should clamp to screen bottom minus toolbar height.
      expect(rect.bottom, lessThanOrEqualTo(1080));
      expect(rect.top, 1080 - kToolbarSize.height);
    });

    test('does not throw when screen is narrower than toolbar', () {
      final rect = computeToolbarRectBelowWindow(
        windowRect: const Rect.fromLTWH(100, 100, 240, 180),
        screenRect: const Rect.fromLTWH(0, 0, 400, 300),
      );

      expect(rect.left, 0.0);
      expect(rect.width, kToolbarSize.width);
      expect(rect.height, kToolbarSize.height);
    });

    test('clamps toolbar above screen top on non-origin display', () {
      // Secondary display at y=1080 with window near the bottom edge.
      // Window bottom at 2000, gap pushes minY to 2008, which overflows.
      // maxY = 2160 - 44 = 2116, so toolbar fits — but on a very tall window
      // that pushes maxY below screenRect.top, the clamp prevents negative.
      final rect = computeToolbarRectBelowWindow(
        windowRect: const Rect.fromLTWH(100, 1080, 400, 1080),
        screenRect: const Rect.fromLTWH(0, 1080, 1920, 1080),
      );

      expect(rect.top, greaterThanOrEqualTo(1080));
    });
  });
}
