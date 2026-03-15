import 'package:a_snap/models/qr_code.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('QrCodeResult.maybeParse', () {
    test('parses a valid QR payload and bounds', () {
      final result = QrCodeResult.maybeParse({
        'payload': 'https://example.com',
        'x': 12,
        'y': 34.5,
        'width': 56,
        'height': 78.25,
      });

      expect(result, isNotNull);
      expect(result!.payload, 'https://example.com');
      expect(result.bounds.left, 12);
      expect(result.bounds.top, 34.5);
      expect(result.bounds.width, 56);
      expect(result.bounds.height, 78.25);
    });

    test('rejects empty payloads and non-positive sizes', () {
      expect(
        QrCodeResult.maybeParse({
          'payload': '',
          'x': 1,
          'y': 2,
          'width': 3,
          'height': 4,
        }),
        isNull,
      );
      expect(
        QrCodeResult.maybeParse({
          'payload': 'text',
          'x': 1,
          'y': 2,
          'width': 0,
          'height': 4,
        }),
        isNull,
      );
      expect(
        QrCodeResult.maybeParse({
          'payload': 'text',
          'x': 1,
          'y': 2,
          'width': 3,
          'height': -1,
        }),
        isNull,
      );
    });
  });
}
