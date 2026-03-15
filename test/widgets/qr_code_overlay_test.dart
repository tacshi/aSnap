import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:a_snap/models/qr_code.dart';
import 'package:a_snap/services/window_service.dart';
import 'package:a_snap/widgets/qr_code_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeWindowService extends WindowService {
  _FakeWindowService(this.results);

  final List<QrCodeResult> results;
  int detectCalls = 0;

  @override
  Future<List<QrCodeResult>> detectQRCodes({
    required Uint8List pngBytes,
  }) async {
    detectCalls++;
    return results;
  }
}

Future<ui.Image> _createTestImage({int width = 100, int height = 50}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = const Color(0xFF202830),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  picture.dispose();
  return image;
}

Widget _buildOverlayHarness({
  required ui.Image image,
  required WindowService windowService,
  required ValueChanged<String> onCopy,
  required Rect imageDisplayRect,
  required Size imagePixelSize,
  Offset imagePixelOrigin = Offset.zero,
  Future<Uint8List?> Function(ui.Image image)? pngBytesLoader,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          key: const ValueKey('host'),
          width: 240,
          height: 180,
          child: Stack(
            children: [
              Positioned.fill(
                child: QrCodeOverlay(
                  image: image,
                imageDisplayRect: imageDisplayRect,
                imagePixelSize: imagePixelSize,
                imagePixelOrigin: imagePixelOrigin,
                windowService: windowService,
                pngBytesLoader: pngBytesLoader,
                onCopy: onCopy,
                enabled: true,
              ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

Future<void> _pumpOverlayReady(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 10));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('QrCodeOverlay', () {
    testWidgets('maps QR bounds using origin and display scale', (tester) async {
      final image = await _createTestImage();
      final windowService = _FakeWindowService([
        const QrCodeResult(
          payload: 'qr-payload',
          bounds: Rect.fromLTWH(30, 20, 50, 20),
        ),
      ]);
      final copied = <String>[];

      await tester.pumpWidget(
        _buildOverlayHarness(
          image: image,
          windowService: windowService,
          onCopy: copied.add,
          imageDisplayRect: const Rect.fromLTWH(20, 30, 200, 100),
          imagePixelSize: const Size(100, 50),
          imagePixelOrigin: const Offset(20, 10),
          pngBytesLoader: (_) async => Uint8List.fromList([1, 2, 3]),
        ),
      );
      await _pumpOverlayReady(tester);

      expect(windowService.detectCalls, 1);
      expect(find.text('Click to copy'), findsOneWidget);

      final hostTopLeft = tester.getTopLeft(find.byKey(const ValueKey('host')));
      await tester.tapAt(hostTopLeft + const Offset(25, 35));
      await tester.pump();
      expect(copied, isEmpty);

      await tester.tapAt(hostTopLeft + const Offset(90, 70));
      await tester.pump();
      expect(copied, ['qr-payload']);
    });

    testWidgets('hides the label when the highlight is too small', (
      tester,
    ) async {
      final image = await _createTestImage();
      final windowService = _FakeWindowService([
        const QrCodeResult(
          payload: 'small-qr',
          bounds: Rect.fromLTWH(10, 10, 8, 8),
        ),
      ]);

      await tester.pumpWidget(
        _buildOverlayHarness(
          image: image,
          windowService: windowService,
          onCopy: (_) {},
          imageDisplayRect: const Rect.fromLTWH(0, 0, 100, 50),
          imagePixelSize: const Size(100, 50),
          pngBytesLoader: (_) async => Uint8List.fromList([1]),
        ),
      );
      await _pumpOverlayReady(tester);

      expect(find.text('Click to copy'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
