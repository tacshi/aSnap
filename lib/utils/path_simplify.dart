import 'dart:ui';

import '../models/annotation_hit_test.dart';

/// Simplifies a polyline path using the Ramer-Douglas-Peucker algorithm.
///
/// Reduces the number of points while preserving the overall shape.
/// [epsilon] controls the maximum allowed deviation from the original path
/// (in image pixel units).
List<Offset> simplifyPath(List<Offset> points, {double epsilon = 1.5}) {
  if (points.length < 3) return points;
  return _rdpSimplify(points, 0, points.length - 1, epsilon);
}

List<Offset> _rdpSimplify(
  List<Offset> points,
  int start,
  int end,
  double epsilon,
) {
  if (end - start < 2) {
    return [points[start], points[end]];
  }

  // Find the point with the maximum distance from the line(start, end).
  double maxDist = 0;
  int maxIndex = start;
  for (int i = start + 1; i < end; i++) {
    final d = distanceToLineSegment(points[i], points[start], points[end]);
    if (d > maxDist) {
      maxDist = d;
      maxIndex = i;
    }
  }

  if (maxDist > epsilon) {
    // Recurse on both halves.
    final left = _rdpSimplify(points, start, maxIndex, epsilon);
    final right = _rdpSimplify(points, maxIndex, end, epsilon);
    // Merge, avoiding duplicate at the split point.
    return [...left, ...right.skip(1)];
  } else {
    // All intermediate points are within epsilon — keep only endpoints.
    return [points[start], points[end]];
  }
}
