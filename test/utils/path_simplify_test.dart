import 'package:flutter_test/flutter_test.dart';
import 'package:a_snap/utils/path_simplify.dart';

void main() {
  group('simplifyPath (Ramer-Douglas-Peucker)', () {
    test('returns same list for fewer than 3 points', () {
      const points = [Offset(0, 0), Offset(10, 10)];
      expect(simplifyPath(points), points);
    });

    test('collinear points are simplified to endpoints', () {
      const points = [
        Offset(0, 0),
        Offset(25, 0),
        Offset(50, 0),
        Offset(75, 0),
        Offset(100, 0),
      ];
      final result = simplifyPath(points, epsilon: 1.5);
      expect(result, [const Offset(0, 0), const Offset(100, 0)]);
    });

    test('preserves points that deviate beyond epsilon', () {
      const points = [
        Offset(0, 0),
        Offset(50, 20), // 20px from line (0,0)→(100,0), well above epsilon
        Offset(100, 0),
      ];
      final result = simplifyPath(points, epsilon: 1.5);
      expect(result.length, 3);
      expect(result, points);
    });

    test('removes intermediate point within epsilon', () {
      const points = [
        Offset(0, 0),
        Offset(50, 0.5), // 0.5px from line, within default epsilon 1.5
        Offset(100, 0),
      ];
      final result = simplifyPath(points, epsilon: 1.5);
      expect(result, [const Offset(0, 0), const Offset(100, 0)]);
    });

    test('simplifies a zigzag path partially', () {
      const points = [
        Offset(0, 0),
        Offset(20, 10), // significant deviation
        Offset(40, 0),
        Offset(60, 10), // significant deviation
        Offset(80, 0),
        Offset(100, 0),
      ];
      final result = simplifyPath(points, epsilon: 1.5);
      // All zigzag peaks deviate > 1.5px, so they should be kept.
      expect(result.length, greaterThanOrEqualTo(4));
      // First and last points always preserved.
      expect(result.first, const Offset(0, 0));
      expect(result.last, const Offset(100, 0));
    });

    test('single point returns as-is', () {
      const points = [Offset(5, 5)];
      expect(simplifyPath(points), points);
    });

    test('empty list returns as-is', () {
      expect(simplifyPath(const []), isEmpty);
    });
  });
}
