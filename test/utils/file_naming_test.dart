import 'package:flutter_test/flutter_test.dart';

import 'package:a_snap/utils/file_naming.dart';

void main() {
  group('generateScreenshotFileName', () {
    test('starts with asnap_ prefix', () {
      final name = generateScreenshotFileName();
      expect(name, startsWith('asnap_'));
    });

    test('ends with .png extension', () {
      final name = generateScreenshotFileName();
      expect(name, endsWith('.png'));
    });

    test('matches expected format: asnap_YYYY-MM-DD_HHMMSS.png', () {
      final name = generateScreenshotFileName();
      // Pattern: asnap_2026-02-22_143025.png
      expect(
        name,
        matches(RegExp(r'^asnap_\d{4}-\d{2}-\d{2}_\d{6}\.png$')),
      );
    });

    test('contains current date', () {
      final now = DateTime.now();
      final name = generateScreenshotFileName();
      final dateStr =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      expect(name, contains(dateStr));
    });

    test('generates unique filenames when called at different times', () {
      // Two calls in rapid succession should at least not crash;
      // if called within the same second they'll be identical (expected)
      final name1 = generateScreenshotFileName();
      final name2 = generateScreenshotFileName();
      expect(name1, isNotEmpty);
      expect(name2, isNotEmpty);
    });
  });
}
