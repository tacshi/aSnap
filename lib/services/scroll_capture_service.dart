import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../utils/constants.dart';
import 'window_service.dart';

/// A single captured frame, PNG-compressed for memory efficiency.
class _ScrollFrame {
  final Uint8List pngBytes;
  final int pixelWidth;
  final int pixelHeight;

  /// Rows shared with the previous frame (0 for the first frame).
  final int overlapRows;

  const _ScrollFrame({
    required this.pngBytes,
    required this.pixelWidth,
    required this.pixelHeight,
    required this.overlapRows,
  });
}

class ScrollCaptureService {
  /// Called after each frame is captured with the current frame count.
  void Function(int frameCount)? onProgress;

  bool _cancelled = false;

  /// Signal the scroll loop to stop.
  /// If 3+ frames have been captured, the partial result is stitched.
  void requestCancel() {
    _cancelled = true;
  }

  /// Run the full scroll-capture loop: activate window, capture frames,
  /// scroll, detect bottom, stitch into one tall image.
  ///
  /// Returns `null` if cancelled with < 3 frames or if capture fails.
  Future<ui.Image?> captureScrolling({
    required int windowId,
    required ui.Rect windowBounds,
    required WindowService windowService,
  }) async {
    _cancelled = false;
    final frames = <_ScrollFrame>[];
    final stopwatch = Stopwatch()..start();

    try {
      // 1. Activate the target window
      await windowService.activateWindowById(windowId);
      await Future<void>.delayed(const Duration(milliseconds: 150));

      // 2. Capture the first frame
      final firstCapture = await windowService.captureWindow(windowId);
      if (firstCapture == null) return null;

      final firstPng = await _encodePng(
        firstCapture.bytes,
        firstCapture.pixelWidth,
        firstCapture.pixelHeight,
        firstCapture.bytesPerRow,
      );
      if (firstPng == null) return null;

      frames.add(
        _ScrollFrame(
          pngBytes: firstPng,
          pixelWidth: firstCapture.pixelWidth,
          pixelHeight: firstCapture.pixelHeight,
          overlapRows: 0,
        ),
      );

      // Keep raw BGRA of the most recent frame for comparison
      var prevBytes = firstCapture.bytes;
      var prevWidth = firstCapture.pixelWidth;
      var prevHeight = firstCapture.pixelHeight;
      var prevBytesPerRow = firstCapture.bytesPerRow;

      onProgress?.call(frames.length);

      // 3. Scroll loop
      for (var i = 1; i < kScrollMaxFrames; i++) {
        if (_cancelled) break;
        if (stopwatch.elapsed.inSeconds >= kScrollTimeoutSeconds) break;

        // Scroll down
        await windowService.scrollWindow(
          windowId: windowId,
          deltaPixels: kScrollDeltaPixels,
        );
        await Future<void>.delayed(Duration(milliseconds: kScrollSettleMs));

        if (_cancelled) break;

        // Capture next frame
        final capture = await windowService.captureWindow(windowId);
        if (capture == null) break; // window closed or hidden

        // Compare with previous frame
        if (_framesIdentical(
          prevBytes,
          prevWidth,
          prevHeight,
          prevBytesPerRow,
          capture.bytes,
          capture.pixelWidth,
          capture.pixelHeight,
          capture.bytesPerRow,
        )) {
          break; // bottom reached
        }

        // Compute overlap between consecutive frames
        final overlap = _computeOverlap(
          prevBytes,
          prevWidth,
          prevHeight,
          prevBytesPerRow,
          capture.bytes,
          capture.pixelWidth,
          capture.pixelHeight,
          capture.bytesPerRow,
        );

        // PNG-encode and store
        final png = await _encodePng(
          capture.bytes,
          capture.pixelWidth,
          capture.pixelHeight,
          capture.bytesPerRow,
        );
        if (png == null) break;

        frames.add(
          _ScrollFrame(
            pngBytes: png,
            pixelWidth: capture.pixelWidth,
            pixelHeight: capture.pixelHeight,
            overlapRows: overlap,
          ),
        );

        // Replace previous raw frame
        prevBytes = capture.bytes;
        prevWidth = capture.pixelWidth;
        prevHeight = capture.pixelHeight;
        prevBytesPerRow = capture.bytesPerRow;

        onProgress?.call(frames.length);
      }
    } catch (e) {
      debugPrint('[aSnap] Scroll capture error: $e');
    }

    stopwatch.stop();

    // If cancelled with fewer than 3 frames, discard
    if (_cancelled && frames.length < 3) return null;

    // Single frame — just decode and return it directly
    if (frames.length == 1) {
      return _decodePng(frames.first.pngBytes);
    }

    // Stitch all frames into one tall image
    return _stitchFrames(frames);
  }

  // ---------------------------------------------------------------------------
  // PNG encoding / decoding
  // ---------------------------------------------------------------------------

  /// Encode raw BGRA pixels to PNG via a temporary ui.Image.
  Future<Uint8List?> _encodePng(
    Uint8List bgra,
    int width,
    int height,
    int bytesPerRow,
  ) async {
    final image = await _decodeBgra(bgra, width, height, bytesPerRow);
    if (image == null) return null;
    try {
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      return byteData?.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }

  /// Decode raw BGRA pixel bytes into a ui.Image.
  Future<ui.Image?> _decodeBgra(
    Uint8List bgra,
    int width,
    int height,
    int bytesPerRow,
  ) {
    final completer = Completer<ui.Image>();
    try {
      ui.decodeImageFromPixels(
        bgra,
        width,
        height,
        ui.PixelFormat.bgra8888,
        completer.complete,
        rowBytes: bytesPerRow,
      );
    } catch (e) {
      debugPrint('[aSnap] BGRA decode error: $e');
      return Future.value(null);
    }
    return completer.future;
  }

  /// Decode a PNG byte buffer into a ui.Image.
  Future<ui.Image?> _decodePng(Uint8List pngBytes) async {
    try {
      final codec = await ui.instantiateImageCodec(pngBytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      return frame.image;
    } catch (e) {
      debugPrint('[aSnap] PNG decode error: $e');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Frame comparison
  // ---------------------------------------------------------------------------

  /// Check if two raw BGRA frames are effectively identical.
  /// Compares the bottom 30% of prev with the bottom 30% of curr,
  /// sampling every 4th row and every 4th column (~6% of pixels).
  bool _framesIdentical(
    Uint8List prevBytes,
    int prevWidth,
    int prevHeight,
    int prevBytesPerRow,
    Uint8List currBytes,
    int currWidth,
    int currHeight,
    int currBytesPerRow,
  ) {
    // Frames must have the same dimensions
    if (prevWidth != currWidth || prevHeight != currHeight) return false;

    final startRow = (prevHeight * 0.7).toInt();
    int totalDiff = 0;
    int samples = 0;

    for (var y = startRow; y < prevHeight; y += 4) {
      final prevRowOffset = y * prevBytesPerRow;
      final currRowOffset = y * currBytesPerRow;

      for (var x = 0; x < prevWidth; x += 4) {
        final prevIdx = prevRowOffset + x * 4;
        final currIdx = currRowOffset + x * 4;

        // Safety bounds check
        if (prevIdx + 2 >= prevBytes.length ||
            currIdx + 2 >= currBytes.length) {
          continue;
        }

        // B, G, R channels (skip alpha)
        totalDiff += (prevBytes[prevIdx] - currBytes[currIdx]).abs();
        totalDiff += (prevBytes[prevIdx + 1] - currBytes[currIdx + 1]).abs();
        totalDiff += (prevBytes[prevIdx + 2] - currBytes[currIdx + 2]).abs();
        samples += 3;
      }
    }

    if (samples == 0) return true;
    final avgDiff = totalDiff / samples;
    return avgDiff < 8.0;
  }

  // ---------------------------------------------------------------------------
  // Overlap detection
  // ---------------------------------------------------------------------------

  /// Find how many rows at the bottom of the previous frame match the top
  /// of the current frame. Returns 0 if no reliable overlap is found.
  ///
  /// Searches up to 500px of overlap (covers most scroll amounts at Retina).
  int _computeOverlap(
    Uint8List prevBytes,
    int prevWidth,
    int prevHeight,
    int prevBytesPerRow,
    Uint8List currBytes,
    int currWidth,
    int currHeight,
    int currBytesPerRow,
  ) {
    if (prevWidth != currWidth) return 0;

    final maxSearch = (prevHeight * 0.6).toInt().clamp(0, 500);
    const requiredConsecutive = 3;
    const rowThreshold = 12.0; // max average SAD per sampled pixel per channel

    int consecutiveMatches = 0;
    int firstMatchOffset = 0;

    // For each candidate overlap offset (how many rows overlap):
    // Compare prevFrame row (prevHeight - offset + r) with currFrame row (r)
    for (var offset = 1; offset <= maxSearch; offset++) {
      final prevRow = prevHeight - offset;
      if (prevRow < 0) break;

      // Compare this single row pair
      final match = _rowsMatch(
        prevBytes,
        prevBytesPerRow,
        prevRow,
        currBytes,
        currBytesPerRow,
        0 + (offset - 1 - (firstMatchOffset - 1)).clamp(0, currHeight - 1),
        prevWidth,
        rowThreshold,
      );

      if (!match) {
        // Reset and try with this offset as a fresh start
        consecutiveMatches = 0;
        continue;
      }

      if (consecutiveMatches == 0) {
        firstMatchOffset = offset;
      }
      consecutiveMatches++;

      if (consecutiveMatches >= requiredConsecutive) {
        return firstMatchOffset;
      }
    }

    // Fallback: use a simple approach — try to find where top of curr
    // appears in bottom of prev by checking fixed offsets
    return _computeOverlapSimple(
      prevBytes,
      prevWidth,
      prevHeight,
      prevBytesPerRow,
      currBytes,
      currWidth,
      currHeight,
      currBytesPerRow,
      maxSearch,
    );
  }

  /// Simpler overlap detection: for each candidate overlap amount, compare
  /// the overlapping region row by row.
  int _computeOverlapSimple(
    Uint8List prevBytes,
    int prevWidth,
    int prevHeight,
    int prevBytesPerRow,
    Uint8List currBytes,
    int currWidth,
    int currHeight,
    int currBytesPerRow,
    int maxSearch,
  ) {
    const requiredConsecutive = 3;
    const rowThreshold = 12.0;

    for (var overlap = maxSearch; overlap >= requiredConsecutive; overlap--) {
      var matchingRows = 0;

      for (var r = 0; r < overlap && r < currHeight; r++) {
        final prevRow = prevHeight - overlap + r;
        if (prevRow < 0) break;

        if (_rowsMatch(
          prevBytes,
          prevBytesPerRow,
          prevRow,
          currBytes,
          currBytesPerRow,
          r,
          prevWidth,
          rowThreshold,
        )) {
          matchingRows++;
        }
      }

      // If most rows match (allow 10% tolerance for anti-aliasing artifacts)
      if (matchingRows >= overlap * 0.9) {
        return overlap;
      }
    }

    return 0;
  }

  /// Compare a single row from two frames using sampled SAD.
  bool _rowsMatch(
    Uint8List aBytes,
    int aBytesPerRow,
    int aRow,
    Uint8List bBytes,
    int bBytesPerRow,
    int bRow,
    int width,
    double threshold,
  ) {
    final aOffset = aRow * aBytesPerRow;
    final bOffset = bRow * bBytesPerRow;
    int totalDiff = 0;
    int samples = 0;

    for (var x = 0; x < width; x += 2) {
      final aIdx = aOffset + x * 4;
      final bIdx = bOffset + x * 4;

      if (aIdx + 2 >= aBytes.length || bIdx + 2 >= bBytes.length) continue;

      totalDiff += (aBytes[aIdx] - bBytes[bIdx]).abs();
      totalDiff += (aBytes[aIdx + 1] - bBytes[bIdx + 1]).abs();
      totalDiff += (aBytes[aIdx + 2] - bBytes[bIdx + 2]).abs();
      samples += 3;
    }

    if (samples == 0) return true;
    return (totalDiff / samples) < threshold;
  }

  // ---------------------------------------------------------------------------
  // Stitching
  // ---------------------------------------------------------------------------

  /// Stitch all captured frames into one tall image.
  /// Decodes each PNG frame one at a time to limit peak memory.
  Future<ui.Image?> _stitchFrames(List<_ScrollFrame> frames) async {
    if (frames.isEmpty) return null;

    final width = frames.first.pixelWidth;

    // Compute total height
    var totalHeight = frames.first.pixelHeight;
    for (var i = 1; i < frames.length; i++) {
      totalHeight += frames[i].pixelHeight - frames[i].overlapRows;
    }

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(
      recorder,
      ui.Rect.fromLTWH(0, 0, width.toDouble(), totalHeight.toDouble()),
    );

    var yOffset = 0.0;

    for (var i = 0; i < frames.length; i++) {
      final frame = frames[i];
      final image = await _decodePng(frame.pngBytes);
      if (image == null) continue;

      // For frames after the first, skip the overlapping top rows
      final srcTop = (i == 0) ? 0.0 : frame.overlapRows.toDouble();
      final srcRect = ui.Rect.fromLTWH(
        0,
        srcTop,
        frame.pixelWidth.toDouble(),
        frame.pixelHeight.toDouble() - srcTop,
      );
      final dstRect = ui.Rect.fromLTWH(
        0,
        yOffset,
        frame.pixelWidth.toDouble(),
        frame.pixelHeight.toDouble() - srcTop,
      );

      canvas.drawImageRect(image, srcRect, dstRect, ui.Paint());
      image.dispose();

      yOffset += frame.pixelHeight - (i == 0 ? 0 : frame.overlapRows);
    }

    final picture = recorder.endRecording();
    try {
      return await picture.toImage(width, totalHeight);
    } finally {
      picture.dispose();
    }
  }
}
