import 'dart:typed_data';

import 'package:super_clipboard/super_clipboard.dart';

class ClipboardService {
  Future<bool> copyImage(Uint8List pngBytes) async {
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) return false;

    final item = DataWriterItem();
    item.add(Formats.png(pngBytes));
    await clipboard.write([item]);
    return true;
  }
}
