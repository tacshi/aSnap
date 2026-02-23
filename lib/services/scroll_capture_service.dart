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

  /// Rows shared with the previous stored frame (0 for the first frame).
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

  /// Called with an updated running composite image for live preview.
  void Function(ui.Image previewImage)? onPreviewUpdated;

  bool _cancelled = false;
  Timer? _captureTimer;
  final List<_ScrollFrame> _frames = [];
  Stopwatch? _stopwatch;

  /// Raw BGRA of the most recent frame (for identity comparison).
  Uint8List? _prevBytes;
  int _prevWidth = 0;
  int _prevHeight = 0;
  int _prevBytesPerRow = 0;

  /// Height of the last *stored* frame (for overlap computation).
  /// Overlap must be relative to the previous stored frame because skipped
  /// frames are not included in the stitched output.
  int _lastStoredHeight = 0;

  /// Column samples for the last stored frame (for overlap computation).
  List<List<double>>? _lastStoredCols;

  /// Last computed scroll offset; used as prediction for faster search.
  int _predictedOffset = 0;

  @visibleForTesting
  set predictedOffset(int value) => _predictedOffset = value;

  /// Running composite image for the live preview panel.
  ui.Image? _runningImage;

  /// Prevents concurrent _captureFrame() calls from overlapping.
  bool _captureInProgress = false;

  /// The screen region being captured (CG coordinates).
  ui.Rect? _captureRegion;
  WindowService? _windowService;

  /// Signal the capture loop to stop (Esc pressed during capture).
  void requestCancel() {
    _cancelled = true;
    _captureTimer?.cancel();
    _captureTimer = null;
    _runningImage?.dispose();
    _runningImage = null;
  }

  /// Start the manual capture loop: poll [region] at ~kScrollCaptureFps fps.
  /// Frames are compared, overlap-detected, and stored for stitching.
  /// Call [stopCapture] to finish and get the stitched result.
  void startManualCapture(ui.Rect region, WindowService windowService) {
    _cancelled = false;
    _captureInProgress = false;
    _frames.clear();
    _prevBytes = null;
    _lastStoredCols = null;
    _predictedOffset = 0;
    _runningImage?.dispose();
    _runningImage = null;
    _captureRegion = region;
    _windowService = windowService;
    _stopwatch = Stopwatch()..start();

    final intervalMs = (1000 / kScrollCaptureFps).round();
    _captureTimer = Timer.periodic(
      Duration(milliseconds: intervalMs),
      (_) => _captureFrame(),
    );
  }

  /// Stop the capture timer and stitch all frames into one tall image.
  /// Returns null if fewer than 1 frame was captured.
  Future<ui.Image?> stopCapture() async {
    _captureTimer?.cancel();
    _captureTimer = null;
    // Mark cancelled so any in-flight _captureFrame exits early after its
    // current await points and does not mutate/dispose the final image.
    _cancelled = true;

    // Wait until an in-flight frame capture/update completes. Without this,
    // stopCapture can race with _updateRunningPreview and return an image that
    // gets disposed right after Done is clicked.
    var spins = 0;
    while (_captureInProgress && spins < 200) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      spins++;
    }

    _stopwatch?.stop();
    _prevBytes = null;
    _lastStoredCols = null;
    _predictedOffset = 0;
    // Prefer the already-stitched live composite. This avoids a second heavy
    // full stitch pass when the user clicks Done and makes finishing instant.
    final running = _runningImage;
    _runningImage = null;
    if (running != null) {
      return running;
    }

    if (_frames.isEmpty) return null;

    // Fallback path when live preview wasn't available.
    if (_frames.length == 1) {
      return _decodePng(_frames.first.pngBytes);
    }
    return _stitchFrames(_frames);
  }

  Future<void> _captureFrame() async {
    if (_cancelled) return;
    if (_captureInProgress) return; // prevent reentrant calls
    _captureInProgress = true;

    final region = _captureRegion;
    final ws = _windowService;
    if (region == null || ws == null) {
      _captureInProgress = false;
      return;
    }

    // Enforce limits
    if (_frames.length >= kScrollMaxFrames) {
      _captureTimer?.cancel();
      _captureTimer = null;
      _captureInProgress = false;
      return;
    }
    if (_stopwatch != null &&
        _stopwatch!.elapsed.inSeconds >= kScrollTimeoutSeconds) {
      _captureTimer?.cancel();
      _captureTimer = null;
      _captureInProgress = false;
      return;
    }

    try {
      final capture = await ws.captureRegion(region);
      if (capture == null || _cancelled) {
        _captureInProgress = false;
        return;
      }

      // First frame — always store it
      if (_frames.isEmpty) {
        final png = await _encodePng(
          capture.bytes,
          capture.pixelWidth,
          capture.pixelHeight,
          capture.bytesPerRow,
        );
        if (png == null) {
          _captureInProgress = false;
          return;
        }

        final frame = _ScrollFrame(
          pngBytes: png,
          pixelWidth: capture.pixelWidth,
          pixelHeight: capture.pixelHeight,
          overlapRows: 0,
        );
        _frames.add(frame);

        _prevBytes = capture.bytes;
        _prevWidth = capture.pixelWidth;
        _prevHeight = capture.pixelHeight;
        _prevBytesPerRow = capture.bytesPerRow;

        _lastStoredHeight = capture.pixelHeight;
        _lastStoredCols = columnSamples(
          capture.bytes,
          capture.pixelWidth,
          capture.pixelHeight,
          capture.bytesPerRow,
        );

        await _updateRunningPreview(frame);
        onProgress?.call(_frames.length);
        _captureInProgress = false;
        return;
      }

      // Compare with most recent frame — skip if identical (no scroll)
      if (framesIdentical(
        _prevBytes!,
        _prevWidth,
        _prevHeight,
        _prevBytesPerRow,
        capture.bytes,
        capture.pixelWidth,
        capture.pixelHeight,
        capture.bytesPerRow,
      )) {
        _captureInProgress = false;
        return; // no scroll happened
      }

      // Compute overlap against the last *stored* frame (not the latest
      // captured frame) because the stitcher only uses stored frames.
      final currCols = columnSamples(
        capture.bytes,
        capture.pixelWidth,
        capture.pixelHeight,
        capture.bytesPerRow,
      );
      final overlap = computeOverlap(
        _lastStoredCols!,
        currCols,
        _lastStoredHeight,
        capture.pixelHeight,
      );

      // Always update prev for identity comparison
      _prevBytes = capture.bytes;
      _prevWidth = capture.pixelWidth;
      _prevHeight = capture.pixelHeight;
      _prevBytesPerRow = capture.bytesPerRow;

      // When overlap is 0 the user scrolled too fast for a match.  Update the
      // stored-frame reference so subsequent frames compare against recent
      // content (breaks the stale-reference cascade) but don't store this
      // frame — avoids visible content duplication at segment boundaries.
      if (overlap == 0) {
        debugPrint(
          '[aSnap] manual scroll: no overlap — updating reference, '
          'skipping frame',
        );
        _lastStoredHeight = capture.pixelHeight;
        _lastStoredCols = currCols;
        _predictedOffset = 0;
        _captureInProgress = false;
        return;
      }

      // PNG-encode and store
      final png = await _encodePng(
        capture.bytes,
        capture.pixelWidth,
        capture.pixelHeight,
        capture.bytesPerRow,
      );
      if (png == null) {
        _captureInProgress = false;
        return;
      }

      debugPrint(
        '[aSnap] manual scroll frame ${_frames.length}: '
        '${capture.pixelWidth}x${capture.pixelHeight} overlap=$overlap',
      );

      final frame = _ScrollFrame(
        pngBytes: png,
        pixelWidth: capture.pixelWidth,
        pixelHeight: capture.pixelHeight,
        overlapRows: overlap,
      );
      _frames.add(frame);

      // Update last stored frame reference
      _lastStoredHeight = capture.pixelHeight;
      _lastStoredCols = currCols;
      _predictedOffset = capture.pixelHeight - overlap;

      await _updateRunningPreview(frame);
      onProgress?.call(_frames.length);
    } catch (e) {
      debugPrint('[aSnap] Manual scroll capture error: $e');
    } finally {
      _captureInProgress = false;
    }
  }

  // ---------------------------------------------------------------------------
  // Live preview (incremental stitch)
  // ---------------------------------------------------------------------------

  /// Incrementally stitch a new frame onto the running composite image
  /// and notify the preview listener.
  Future<void> _updateRunningPreview(_ScrollFrame frame) async {
    final newFrame = await _decodePng(frame.pngBytes);
    if (newFrame == null) return;

    if (_runningImage == null) {
      // First frame — use it directly as the running image
      _runningImage = newFrame;
      onPreviewUpdated?.call(_runningImage!);
      return;
    }

    final prev = _runningImage!;
    final newHeight = prev.height + newFrame.height - frame.overlapRows;
    if (newHeight <= 0) {
      newFrame.dispose();
      return;
    }

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(
      recorder,
      ui.Rect.fromLTWH(0, 0, prev.width.toDouble(), newHeight.toDouble()),
    );

    // Draw existing composite
    canvas.drawImage(prev, ui.Offset.zero, ui.Paint());

    // Draw new frame, skipping overlap rows
    final srcTop = frame.overlapRows.toDouble();
    final srcHeight = newFrame.height.toDouble() - srcTop;
    canvas.drawImageRect(
      newFrame,
      ui.Rect.fromLTWH(0, srcTop, newFrame.width.toDouble(), srcHeight),
      ui.Rect.fromLTWH(
        0,
        prev.height.toDouble(),
        newFrame.width.toDouble(),
        srcHeight,
      ),
      ui.Paint(),
    );
    newFrame.dispose();

    final picture = recorder.endRecording();
    try {
      final composite = await picture.toImage(prev.width, newHeight);
      prev.dispose();
      _runningImage = composite;
      onPreviewUpdated?.call(_runningImage!);
    } finally {
      picture.dispose();
    }
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
  @visibleForTesting
  static bool framesIdentical(
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
  // Overlap detection — column-sampling approach
  // ---------------------------------------------------------------------------
  //
  // Inspired by wayscrollshot (https://github.com/jswysnemc/wayscrollshot).
  // Instead of matching small pixel blocks (easily fooled by repeating content
  // like Twitter feeds), sample evenly-spaced columns per row and compare ALL
  // overlapping rows for each candidate offset. The correct offset produces the
  // lowest mean absolute difference across all rows — fixed headers are
  // naturally handled because they're a minority of the total rows.

  /// Compute column samples for a frame: for each row, compute the grayscale
  /// value at [kColSamples] evenly-spaced columns across the full width.
  /// Returns a list of [height] entries, each with [kColSamples] doubles.
  static const kColSamples = 10;

  @visibleForTesting
  static List<List<double>> columnSamples(
    Uint8List bytes,
    int width,
    int height,
    int bytesPerRow,
  ) {
    // Evenly space samples across the width, avoiding the very edges
    final step = width / (kColSamples + 1);
    final xPositions = List.generate(
      kColSamples,
      (i) => (step * (i + 1)).toInt().clamp(0, width - 1),
    );

    return List.generate(height, (y) {
      return List.generate(kColSamples, (s) {
        final x = xPositions[s];
        final idx = y * bytesPerRow + x * 4;
        if (idx + 2 >= bytes.length) return 0.0;
        // BGRA format → grayscale: 0.114*B + 0.587*G + 0.299*R
        return 0.114 * bytes[idx] +
            0.587 * bytes[idx + 1] +
            0.299 * bytes[idx + 2];
      });
    });
  }

  /// Compute the mean absolute difference between prevCols and currCols
  /// for a given [offset] (= number of new rows = scroll amount).
  ///
  /// At offset `o`, prevFrame's row `o + i` is compared with currFrame's
  /// row `i` for all i in `[0, min(prevH - o, currH))`.
  @visibleForTesting
  static double colDiff(
    List<List<double>> prevCols,
    List<List<double>> currCols,
    int offset, {
    int skipTopRows = 0,
  }) {
    final prevH = prevCols.length;
    final currH = currCols.length;
    if (prevH == 0 || currH == 0) return double.infinity;
    if (offset <= 0 || offset >= prevH) return double.infinity;

    final len = (prevH - offset) < currH ? (prevH - offset) : currH;
    if (len <= 0) return double.infinity;

    final start = skipTopRows.clamp(0, len - 1);
    final effectiveLen = len - start;
    // Too little comparable area -> unreliable offset.
    if (effectiveLen < 8) return double.infinity;

    final numGroups = prevCols[0].length;
    double sum = 0;
    double weightSum = 0;
    int count = 0;

    for (var i = start; i < len; i++) {
      final pRow = prevCols[offset + i];
      final cRow = currCols[i];
      // Slightly favor lower rows where scrolled content is typically denser.
      final progress = (i - start) / effectiveLen;
      final rowWeight = 1.0 + progress * 0.25;
      for (var g = 0; g < numGroups; g++) {
        sum += (pRow[g] - cRow[g]).abs() * rowWeight;
        weightSum += rowWeight;
        count++;
      }
    }

    return count > 0 && weightSum > 0 ? sum / weightSum : double.infinity;
  }

  /// Estimate the number of pinned rows at the top (sticky header).
  /// Rows that are nearly identical at the same Y in both frames are treated
  /// as fixed and excluded from overlap matching.
  static int _estimatePinnedTopRows(
    List<List<double>> prevCols,
    List<List<double>> currCols,
  ) {
    if (prevCols.isEmpty || currCols.isEmpty) return 0;
    final h = prevCols.length < currCols.length
        ? prevCols.length
        : currCols.length;
    if (h <= 0) return 0;

    final maxScan = (h * 0.35).toInt().clamp(0, h);
    const rowDiffThreshold = 4.0;
    int pinned = 0;
    int mismatchStreak = 0;

    for (var y = 0; y < maxScan; y++) {
      final pRow = prevCols[y];
      final cRow = currCols[y];
      var diff = 0.0;
      final groups = pRow.length < cRow.length ? pRow.length : cRow.length;
      for (var g = 0; g < groups; g++) {
        diff += (pRow[g] - cRow[g]).abs();
      }
      diff /= groups > 0 ? groups : 1;

      if (diff <= rowDiffThreshold) {
        pinned = y + 1;
        mismatchStreak = 0;
      } else {
        mismatchStreak++;
        // Require a small streak before we stop to tolerate noisy rows.
        if (mismatchStreak >= 3) break;
      }
    }
    return pinned;
  }

  /// Find the overlap between two frames using column-sample comparison.
  ///
  /// Searches outward from the predicted offset for fast convergence.
  /// The offset with the minimum column diff wins.
  @visibleForTesting
  int computeOverlap(
    List<List<double>> prevCols,
    List<List<double>> currCols,
    int prevHeight,
    int currHeight,
  ) {
    if (prevHeight != currHeight) return 0;

    const diffThreshold = 8.0; // max acceptable average column diff
    final minOffset = (prevHeight * 0.01).ceil().clamp(2, 24);
    final maxOffset = (prevHeight * 0.85).toInt();
    final pinnedTopRows = _estimatePinnedTopRows(prevCols, currCols);

    double bestDiff = double.infinity;
    int bestOffset = 0;

    // Build search order: expand outward from predicted offset
    final predict = _predictedOffset.clamp(minOffset, maxOffset);
    final searchOrder = <int>[predict];
    for (var delta = 1; delta <= maxOffset; delta++) {
      if (predict + delta <= maxOffset) searchOrder.add(predict + delta);
      if (predict - delta >= minOffset) searchOrder.add(predict - delta);
    }

    for (final offset in searchOrder) {
      final diff = colDiff(
        prevCols,
        currCols,
        offset,
        skipTopRows: pinnedTopRows,
      );

      if (diff < bestDiff) {
        bestDiff = diff;
        bestOffset = offset;
      }

      // Early termination: only stop for near-perfect matches (diff ≈ 0)
      if (bestDiff < 0.5) break;
    }

    if (bestDiff > diffThreshold || bestOffset <= 0) return 0;

    final overlap = prevHeight - bestOffset;
    return overlap.clamp(0, currHeight);
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
