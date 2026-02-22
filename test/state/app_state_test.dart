import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:a_snap/state/app_state.dart';

void main() {
  late AppState state;

  setUp(() {
    state = AppState();
  });

  group('initial state', () {
    test('starts idle with null fields', () {
      expect(state.status, CaptureStatus.idle);
      expect(state.screenshotBytes, isNull);
      expect(state.fullScreenBytes, isNull);
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
    test('stores bytes and transitions to captured', () {
      final bytes = Uint8List.fromList([1, 2, 3]);
      state.setCapturedImage(bytes);

      expect(state.status, CaptureStatus.captured);
      expect(state.screenshotBytes, bytes);
      expect(state.fullScreenBytes, isNull);
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
    test('resets all fields to initial state', () {
      final bytes = Uint8List.fromList([1, 2, 3]);
      state.setCapturedImage(bytes);
      expect(state.status, CaptureStatus.captured);

      state.clear();

      expect(state.status, CaptureStatus.idle);
      expect(state.screenshotBytes, isNull);
      expect(state.fullScreenBytes, isNull);
      expect(state.decodedFullScreen, isNull);
      expect(state.windowRects, isNull);
      expect(state.screenSize, isNull);
      expect(state.screenOrigin, isNull);
    });
  });

  group('state machine transitions', () {
    test('idle → capturing → captured → idle', () {
      expect(state.status, CaptureStatus.idle);

      state.setCapturing();
      expect(state.status, CaptureStatus.capturing);

      state.setCapturedImage(Uint8List.fromList([1]));
      expect(state.status, CaptureStatus.captured);

      state.clear();
      expect(state.status, CaptureStatus.idle);
    });
  });
}
