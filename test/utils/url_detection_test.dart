import 'package:flutter_test/flutter_test.dart';

import 'package:a_snap/utils/url_detection.dart';

void main() {
  group('extractFirstUrl', () {
    test('returns a full http/https URL when present', () {
      expect(
        extractFirstUrl('See https://example.com/path?q=1'),
        'https://example.com/path?q=1',
      );
      expect(
        extractFirstUrl('http://example.com'),
        'http://example.com',
      );
    });

    test('handles www-prefixed domains', () {
      expect(
        extractFirstUrl('Visit www.example.com/test'),
        'https://www.example.com/test',
      );
    });

    test('handles bare domains', () {
      expect(extractFirstUrl('example.com'), 'https://example.com');
      expect(
        extractFirstUrl('Go to sub.example.co.uk/path'),
        'https://sub.example.co.uk/path',
      );
    });

    test('trims trailing punctuation', () {
      expect(
        extractFirstUrl('Open https://example.com).'),
        'https://example.com',
      );
    });

    test('ignores emails and non-URLs', () {
      expect(extractFirstUrl('Contact me at name@example.com'), isNull);
      expect(extractFirstUrl('no url here'), isNull);
    });
  });
}
