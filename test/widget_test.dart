import 'package:flutter_test/flutter_test.dart';

import 'package:a_snap/utils/file_naming.dart';

void main() {
  test('generateScreenshotFileName returns valid filename', () {
    final name = generateScreenshotFileName();
    expect(name, startsWith('asnap_'));
    expect(name, endsWith('.png'));
  });
}
