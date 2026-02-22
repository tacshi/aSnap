import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:a_snap/state/app_state.dart';

/// Create a simple 1x1 test image using PictureRecorder.
Future<Image> _createTestImage() async {
  final recorder = PictureRecorder();
  Canvas(recorder).drawRect(
    const Rect.fromLTWH(0, 0, 1, 1),
    Paint()..color = const Color(0xFFFF0000),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(1, 1);
  picture.dispose();
  return image;
}

void main() {
  late AppState state;

  setUp(() {
    state = AppState();
  });

  group('initial state', () {
    test('starts idle with null fields', () {
      expect(state.status, CaptureStatus.idle);
      expect(state.capturedImage, isNull);
      expect(state.decodedFullScreen, isNull);
      expect(state.windowRects, isNull);
      expect(state.screenSize, isNull);
      expect(state.screenOrigin, isNull);
    });
  });

  group('setCapturing', () {
    test('transitions to capturing and notifies', () {
      var notified = false;
      state.addListener(() => notified = true);

      state.setCapturing();

      expect(state.status, CaptureStatus.capturing);
      expect(notified, isTrue);
    });
  });

  group('setCapturedImage', () {
    testWidgets('stores image and transitions to captured', (tester) async {
      final image = await _createTestImage();
      state.setCapturedImage(image);

      expect(state.status, CaptureStatus.captured);
      expect(state.capturedImage, isNotNull);
      expect(state.decodedFullScreen, isNull);
      expect(state.windowRects, isNull);
      expect(state.screenSize, isNull);
      expect(state.screenOrigin, isNull);
    });
  });

  group('updateWindowRects', () {
    test('updates rects and notifies', () {
      var notified = false;
      state.addListener(() => notified = true);

      final rects = [const Rect.fromLTWH(0, 0, 100, 100)];
      state.updateWindowRects(rects);

      expect(state.windowRects, rects);
      expect(notified, isTrue);
    });
  });

  group('nudge', () {
    test('notifies listeners without changing state', () {
      var notifyCount = 0;
      state.addListener(() => notifyCount++);

      state.nudge();

      expect(notifyCount, 1);
      expect(state.status, CaptureStatus.idle);
    });
  });

  group('clear', () {
    testWidgets('resets all fields to initial state', (tester) async {
      final image = await _createTestImage();
      state.setCapturedImage(image);
      expect(state.status, CaptureStatus.captured);

      state.clear();

      expect(state.status, CaptureStatus.idle);
      expect(state.capturedImage, isNull);
      expect(state.decodedFullScreen, isNull);
      expect(state.windowRects, isNull);
      expect(state.screenSize, isNull);
      expect(state.screenOrigin, isNull);
    });
  });

  group('capturedImageAsPng', () {
    testWidgets('returns PNG bytes from captured image', (tester) async {
      final image = await _createTestImage();
      state.setCapturedImage(image);

      // toByteData(format: png) is a real engine call — needs runAsync.
      final png = await tester.runAsync(() => state.capturedImageAsPng());

      expect(png, isNotNull);
      // PNG magic bytes
      expect(png!.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
    });

    test('returns null when no image captured', () async {
      final png = await state.capturedImageAsPng();
      expect(png, isNull);
    });
  });

  group('state machine transitions', () {
    testWidgets('idle → capturing → captured → idle', (tester) async {
      expect(state.status, CaptureStatus.idle);

      state.setCapturing();
      expect(state.status, CaptureStatus.capturing);

      final image = await _createTestImage();
      state.setCapturedImage(image);
      expect(state.status, CaptureStatus.captured);

      state.clear();
      expect(state.status, CaptureStatus.idle);
    });
  });
}
