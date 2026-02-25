import 'dart:typed_data';

import 'package:a_snap/services/scroll_capture_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Build a synthetic BGRA frame where each pixel has the given [r], [g], [b]
/// values (constant across the frame). Alpha is 255.
Uint8List _solidFrame(int width, int height, int r, int g, int b) {
  final bytesPerRow = width * 4;
  final bytes = Uint8List(height * bytesPerRow);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final idx = y * bytesPerRow + x * 4;
      bytes[idx] = b; // B
      bytes[idx + 1] = g; // G
      bytes[idx + 2] = r; // R
      bytes[idx + 3] = 255; // A
    }
  }
  return bytes;
}

/// Build a BGRA frame with a unique per-row grayscale gradient.
/// Row y has grayscale value (y % 256) across all pixels.
Uint8List _gradientFrame(int width, int height) {
  final bytesPerRow = width * 4;
  final bytes = Uint8List(height * bytesPerRow);
  for (var y = 0; y < height; y++) {
    final v = y % 256;
    for (var x = 0; x < width; x++) {
      final idx = y * bytesPerRow + x * 4;
      bytes[idx] = v; // B
      bytes[idx + 1] = v; // G
      bytes[idx + 2] = v; // R
      bytes[idx + 3] = 255;
    }
  }
  return bytes;
}

/// Build a shifted gradient frame where row y has value (y + scrollAmount) % 256.
Uint8List _shiftedGradientFrame(int width, int height, int scrollAmount) {
  final bytesPerRow = width * 4;
  final bytes = Uint8List(height * bytesPerRow);
  for (var y = 0; y < height; y++) {
    final v = (y + scrollAmount) % 256;
    for (var x = 0; x < width; x++) {
      final idx = y * bytesPerRow + x * 4;
      bytes[idx] = v;
      bytes[idx + 1] = v;
      bytes[idx + 2] = v;
      bytes[idx + 3] = 255;
    }
  }
  return bytes;
}

/// Build a frame with a fixed top header and scrolling body.
/// [scrollAmount] shifts only the body content; header stays unchanged.
Uint8List _stickyHeaderFrame(
  int width,
  int height, {
  required int headerHeight,
  required int scrollAmount,
}) {
  final bytesPerRow = width * 4;
  final bytes = Uint8List(height * bytesPerRow);
  for (var y = 0; y < height; y++) {
    final v = y < headerHeight ? 32 : ((y - headerHeight + scrollAmount) % 256);
    for (var x = 0; x < width; x++) {
      final idx = y * bytesPerRow + x * 4;
      bytes[idx] = v;
      bytes[idx + 1] = v;
      bytes[idx + 2] = v;
      bytes[idx + 3] = 255;
    }
  }
  return bytes;
}

void main() {
  group('framesIdentical', () {
    test('identical solid frames → true', () {
      final a = _solidFrame(20, 20, 128, 128, 128);
      final b = _solidFrame(20, 20, 128, 128, 128);
      expect(
        ScrollCaptureService.framesIdentical(a, 20, 20, 80, b, 20, 20, 80),
        isTrue,
      );
    });

    test('very different frames → false', () {
      final a = _solidFrame(20, 20, 0, 0, 0);
      final b = _solidFrame(20, 20, 255, 255, 255);
      expect(
        ScrollCaptureService.framesIdentical(a, 20, 20, 80, b, 20, 20, 80),
        isFalse,
      );
    });

    test('dimension mismatch → false', () {
      final a = _solidFrame(20, 20, 128, 128, 128);
      final b = _solidFrame(20, 10, 128, 128, 128);
      expect(
        ScrollCaptureService.framesIdentical(a, 20, 20, 80, b, 20, 10, 80),
        isFalse,
      );
    });

    test('nearly identical frames (diff < threshold) → true', () {
      final a = _solidFrame(20, 20, 100, 100, 100);
      final b = _solidFrame(20, 20, 105, 105, 105);
      expect(
        ScrollCaptureService.framesIdentical(a, 20, 20, 80, b, 20, 20, 80),
        isTrue,
      );
    });
  });

  group('columnSamples', () {
    test('returns correct dimensions', () {
      const width = 100;
      const height = 50;
      final bytes = _solidFrame(width, height, 128, 128, 128);
      final result = ScrollCaptureService.columnSamples(
        bytes,
        width,
        height,
        width * 4,
      );
      expect(result.length, height);
      expect(result.first.length, ScrollCaptureService.kColSamples);
    });

    test('height 0 returns empty list', () {
      final result = ScrollCaptureService.columnSamples(
        Uint8List(0),
        100,
        0,
        400,
      );
      expect(result, isEmpty);
    });

    test('solid frame produces uniform column samples per row', () {
      const width = 100;
      const height = 10;
      final bytes = _solidFrame(width, height, 128, 128, 128);
      final result = ScrollCaptureService.columnSamples(
        bytes,
        width,
        height,
        width * 4,
      );
      // All samples in a row should be the same for a solid frame
      for (final row in result) {
        final firstVal = row.first;
        for (final val in row) {
          expect(val, closeTo(firstVal, 0.01));
        }
      }
    });

    test('grayscale calculation is correct', () {
      // Single pixel frame: R=100, G=150, B=200
      // Expected grayscale: 0.114*200 + 0.587*150 + 0.299*100 = 22.8 + 88.05 + 29.9 = 140.75
      const width = 50;
      const height = 1;
      final bytes = _solidFrame(width, height, 100, 150, 200);
      final result = ScrollCaptureService.columnSamples(
        bytes,
        width,
        height,
        width * 4,
      );
      expect(result.length, 1);
      expect(result[0].first, closeTo(140.75, 0.01));
    });
  });

  group('colDiff', () {
    test('identical column data → diff ≈ 0', () {
      final cols = List.generate(10, (_) => List.filled(5, 100.0));
      final diff = ScrollCaptureService.colDiff(cols, cols, 1);
      expect(diff, closeTo(0, 0.01));
    });

    test('completely different data → large diff', () {
      final a = List.generate(10, (_) => List.filled(5, 0.0));
      final b = List.generate(10, (_) => List.filled(5, 200.0));
      final diff = ScrollCaptureService.colDiff(a, b, 1);
      expect(diff, greaterThan(100));
    });

    test('offset = 0 → infinity', () {
      final cols = List.generate(10, (_) => List.filled(5, 100.0));
      expect(ScrollCaptureService.colDiff(cols, cols, 0), double.infinity);
    });

    test('offset >= prevH → infinity', () {
      final cols = List.generate(10, (_) => List.filled(5, 100.0));
      expect(ScrollCaptureService.colDiff(cols, cols, 10), double.infinity);
      expect(ScrollCaptureService.colDiff(cols, cols, 15), double.infinity);
    });

    test('empty lists → infinity', () {
      final empty = <List<double>>[];
      final nonEmpty = List.generate(10, (_) => List.filled(5, 100.0));
      expect(ScrollCaptureService.colDiff(empty, nonEmpty, 1), double.infinity);
      expect(ScrollCaptureService.colDiff(nonEmpty, empty, 1), double.infinity);
      expect(ScrollCaptureService.colDiff(empty, empty, 1), double.infinity);
    });

    test('negative offset → infinity', () {
      final cols = List.generate(10, (_) => List.filled(5, 100.0));
      expect(ScrollCaptureService.colDiff(cols, cols, -5), double.infinity);
    });
  });

  group('fullRowDiff', () {
    test('identical frames at correct offset → diff ≈ 0', () {
      const width = 100;
      const height = 50;
      final frame = _solidFrame(width, height, 128, 128, 128);
      final diff = ScrollCaptureService.fullRowDiff(
        frame,
        width,
        height,
        width * 4,
        frame,
        width,
        height,
        width * 4,
        1,
      );
      expect(diff, closeTo(0, 0.01));
    });

    test('shifted gradient frames → diff ≈ 0 at correct offset', () {
      const width = 100;
      const height = 100;
      const scrollAmount = 20;
      final frameA = _gradientFrame(width, height);
      final frameB = _shiftedGradientFrame(width, height, scrollAmount);
      final diff = ScrollCaptureService.fullRowDiff(
        frameA,
        width,
        height,
        width * 4,
        frameB,
        width,
        height,
        width * 4,
        scrollAmount,
      );
      expect(diff, closeTo(0, 0.01));
    });

    test('wrong offset → large diff', () {
      const width = 100;
      const height = 100;
      const scrollAmount = 20;
      final frameA = _gradientFrame(width, height);
      final frameB = _shiftedGradientFrame(width, height, scrollAmount);
      // Off by 5 pixels
      final diff = ScrollCaptureService.fullRowDiff(
        frameA,
        width,
        height,
        width * 4,
        frameB,
        width,
        height,
        width * 4,
        scrollAmount + 5,
      );
      expect(diff, greaterThan(1.0));
    });

    test('respects skipTopRows', () {
      const width = 100;
      const height = 100;
      // Frame A: rows 0-19 = value 50, rows 20-99 = constant 128
      // Frame B: rows 0-19 = value 200, rows 20-99 = constant 128
      // With offset=1, rows 20+ compare prev[21..] with curr[20..],
      // both constant 128, so diff should be ≈ 0 when skipping top rows.
      final bytesPerRow = width * 4;
      final frameA = Uint8List(height * bytesPerRow);
      final frameB = Uint8List(height * bytesPerRow);
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          final idx = y * bytesPerRow + x * 4;
          if (y < 20) {
            frameA[idx] = 50;
            frameA[idx + 1] = 50;
            frameA[idx + 2] = 50;
            frameB[idx] = 200;
            frameB[idx + 1] = 200;
            frameB[idx + 2] = 200;
          } else {
            frameA[idx] = 128;
            frameA[idx + 1] = 128;
            frameA[idx + 2] = 128;
            frameB[idx] = 128;
            frameB[idx + 1] = 128;
            frameB[idx + 2] = 128;
          }
          frameA[idx + 3] = 255;
          frameB[idx + 3] = 255;
        }
      }

      // Without skipTopRows: large diff because top 20 rows differ
      final diffNoSkip = ScrollCaptureService.fullRowDiff(
        frameA,
        width,
        height,
        width * 4,
        frameB,
        width,
        height,
        width * 4,
        1,
      );
      // With skipTopRows=20: diff ≈ 0 because only matching rows compared
      final diffSkip = ScrollCaptureService.fullRowDiff(
        frameA,
        width,
        height,
        width * 4,
        frameB,
        width,
        height,
        width * 4,
        1,
        skipTopRows: 20,
      );
      expect(diffNoSkip, greaterThan(diffSkip));
      expect(diffSkip, closeTo(0, 0.01));
    });

    test('different widths → infinity', () {
      final a = _solidFrame(100, 50, 128, 128, 128);
      final b = _solidFrame(80, 50, 128, 128, 128);
      expect(
        ScrollCaptureService.fullRowDiff(a, 100, 50, 400, b, 80, 50, 320, 1),
        double.infinity,
      );
    });

    test('bestSoFar causes early return when data is mismatched', () {
      const width = 100;
      const height = 100;
      const scrollAmount = 20;
      final frameA = _gradientFrame(width, height);
      final frameB = _shiftedGradientFrame(width, height, scrollAmount);

      // Wrong offset produces a large diff
      final diffNoBound = ScrollCaptureService.fullRowDiff(
        frameA,
        width,
        height,
        width * 4,
        frameB,
        width,
        height,
        width * 4,
        scrollAmount + 5,
      );
      expect(diffNoBound, greaterThan(1.0));

      // With a tight bestSoFar, should return early with a value > bestSoFar
      const bestSoFar = 0.5;
      final diffBounded = ScrollCaptureService.fullRowDiff(
        frameA,
        width,
        height,
        width * 4,
        frameB,
        width,
        height,
        width * 4,
        scrollAmount + 5,
        bestSoFar: bestSoFar,
      );
      expect(diffBounded, greaterThan(bestSoFar));
    });

    test('bestSoFar does not affect result when data matches well', () {
      const width = 100;
      const height = 100;
      const scrollAmount = 20;
      final frameA = _gradientFrame(width, height);
      final frameB = _shiftedGradientFrame(width, height, scrollAmount);

      // Correct offset with generous bestSoFar should return near-zero diff
      final diff = ScrollCaptureService.fullRowDiff(
        frameA,
        width,
        height,
        width * 4,
        frameB,
        width,
        height,
        width * 4,
        scrollAmount,
        bestSoFar: 100.0,
      );
      expect(diff, closeTo(0, 0.01));
    });

    test('offset out of bounds → infinity', () {
      final frame = _solidFrame(100, 50, 128, 128, 128);
      expect(
        ScrollCaptureService.fullRowDiff(
          frame,
          100,
          50,
          400,
          frame,
          100,
          50,
          400,
          0,
        ),
        double.infinity,
      );
      expect(
        ScrollCaptureService.fullRowDiff(
          frame,
          100,
          50,
          400,
          frame,
          100,
          50,
          400,
          50,
        ),
        double.infinity,
      );
    });
  });

  group('computeOverlap', () {
    test('synthetic shifted frames detect correct overlap', () {
      const width = 100;
      const height = 100;
      const scrollAmount = 20;

      final frameA = _gradientFrame(width, height);
      final colsA = ScrollCaptureService.columnSamples(
        frameA,
        width,
        height,
        width * 4,
      );

      final frameB = _shiftedGradientFrame(width, height, scrollAmount);
      final colsB = ScrollCaptureService.columnSamples(
        frameB,
        width,
        height,
        width * 4,
      );

      final service = ScrollCaptureService();
      service.predictedOffset = 0; // no prediction

      final overlap = service.computeOverlap(colsA, colsB, height, height);
      // overlap = height - scrollAmount = 80
      expect(overlap, height - scrollAmount);
    });

    test('no overlap between unrelated frames → 0', () {
      const width = 100;
      const height = 100;

      // Two completely different solid frames
      final a = _solidFrame(width, height, 50, 50, 50);
      final b = _solidFrame(width, height, 200, 200, 200);
      final colsA = ScrollCaptureService.columnSamples(
        a,
        width,
        height,
        width * 4,
      );
      final colsB = ScrollCaptureService.columnSamples(
        b,
        width,
        height,
        width * 4,
      );

      final service = ScrollCaptureService();
      service.predictedOffset = 0;

      final overlap = service.computeOverlap(colsA, colsB, height, height);
      // Solid frames with uniform color — every offset looks the same.
      // colDiff will be 150.0 at every offset, exceeding the threshold.
      expect(overlap, 0);
    });

    test('different heights → 0', () {
      final cols10 = List.generate(10, (_) => List.filled(5, 100.0));
      final cols20 = List.generate(20, (_) => List.filled(5, 100.0));

      final service = ScrollCaptureService();
      final overlap = service.computeOverlap(cols10, cols20, 10, 20);
      expect(overlap, 0);
    });

    test('predicted offset speeds up search for matching frames', () {
      const width = 100;
      const height = 100;
      const scrollAmount = 30;

      final frameA = _gradientFrame(width, height);
      final colsA = ScrollCaptureService.columnSamples(
        frameA,
        width,
        height,
        width * 4,
      );

      final frameB = _shiftedGradientFrame(width, height, scrollAmount);
      final colsB = ScrollCaptureService.columnSamples(
        frameB,
        width,
        height,
        width * 4,
      );

      final service = ScrollCaptureService();
      service.predictedOffset = scrollAmount; // exact prediction

      final overlap = service.computeOverlap(colsA, colsB, height, height);
      expect(overlap, height - scrollAmount);
    });

    test('handles sticky top header without seam offsets', () {
      const width = 120;
      const height = 140;
      const headerHeight = 28;
      const scrollAmount = 22;

      final frameA = _stickyHeaderFrame(
        width,
        height,
        headerHeight: headerHeight,
        scrollAmount: 0,
      );
      final frameB = _stickyHeaderFrame(
        width,
        height,
        headerHeight: headerHeight,
        scrollAmount: scrollAmount,
      );

      final colsA = ScrollCaptureService.columnSamples(
        frameA,
        width,
        height,
        width * 4,
      );
      final colsB = ScrollCaptureService.columnSamples(
        frameB,
        width,
        height,
        width * 4,
      );

      final service = ScrollCaptureService();
      service.predictedOffset = scrollAmount;

      final overlap = service.computeOverlap(colsA, colsB, height, height);
      expect(overlap, height - scrollAmount);
    });

    test('refinement corrects overlap with BGRA data', () {
      const width = 100;
      const height = 100;
      const scrollAmount = 20;

      final frameA = _gradientFrame(width, height);
      final frameB = _shiftedGradientFrame(width, height, scrollAmount);

      final colsA = ScrollCaptureService.columnSamples(
        frameA,
        width,
        height,
        width * 4,
      );
      final colsB = ScrollCaptureService.columnSamples(
        frameB,
        width,
        height,
        width * 4,
      );

      final service = ScrollCaptureService();
      service.predictedOffset = 0;

      final overlap = service.computeOverlap(
        colsA,
        colsB,
        height,
        height,
        prevBytes: frameA,
        prevWidth: width,
        prevBytesPerRow: width * 4,
        currBytes: frameB,
        currWidth: width,
        currBytesPerRow: width * 4,
      );
      expect(overlap, height - scrollAmount);
    });

    test('refinement with sticky header produces correct overlap', () {
      const width = 120;
      const height = 200;
      const headerHeight = 40;
      const scrollAmount = 30;

      final frameA = _stickyHeaderFrame(
        width,
        height,
        headerHeight: headerHeight,
        scrollAmount: 0,
      );
      final frameB = _stickyHeaderFrame(
        width,
        height,
        headerHeight: headerHeight,
        scrollAmount: scrollAmount,
      );

      final colsA = ScrollCaptureService.columnSamples(
        frameA,
        width,
        height,
        width * 4,
      );
      final colsB = ScrollCaptureService.columnSamples(
        frameB,
        width,
        height,
        width * 4,
      );

      final service = ScrollCaptureService();
      service.predictedOffset = scrollAmount;

      final overlap = service.computeOverlap(
        colsA,
        colsB,
        height,
        height,
        prevBytes: frameA,
        prevWidth: width,
        prevBytesPerRow: width * 4,
        currBytes: frameB,
        currWidth: width,
        currBytesPerRow: width * 4,
      );
      expect(overlap, height - scrollAmount);
    });

    test('refinement picks lowest-diff offset without bias', () {
      const width = 100;
      const height = 100;

      final frameA = _gradientFrame(width, height);
      final frameB = _shiftedGradientFrame(width, height, 20);

      final colsA = ScrollCaptureService.columnSamples(
        frameA,
        width,
        height,
        width * 4,
      );
      final colsB = ScrollCaptureService.columnSamples(
        frameB,
        width,
        height,
        width * 4,
      );

      final service = ScrollCaptureService();
      service.predictedOffset = 20;

      // Refinement should pick the offset with strictly lowest fullRowDiff.
      final overlap = service.computeOverlap(
        colsA,
        colsB,
        height,
        height,
        prevBytes: frameA,
        prevWidth: width,
        prevBytesPerRow: width * 4,
        currBytes: frameB,
        currWidth: width,
        currBytesPerRow: width * 4,
      );
      expect(overlap, height - 20);
    });
  });
}
