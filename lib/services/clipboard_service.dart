import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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

  Future<Uint8List?> readPngImage() async {
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) return null;

    final reader = await clipboard.read();
    if (!reader.canProvide(Formats.png)) return null;
    final completer = Completer<Uint8List?>();
    final progress = reader.getFile(
      Formats.png,
      (file) async {
        try {
          completer.complete(await file.readAll());
        } catch (error, stackTrace) {
          completer.completeError(error, stackTrace);
        }
      },
      onError: (error) {
        if (!completer.isCompleted) {
          completer.completeError(error);
        }
      },
    );
    if (progress == null) return null;
    return completer.future;
  }

  Future<bool> containsMatchingImage(Uint8List expectedPngBytes) async {
    final clipboardBytes = await readPngImage();
    if (clipboardBytes == null) return false;
    return listEquals(clipboardBytes, expectedPngBytes);
  }

  Future<bool> copyText(String text) async {
    if (text.isEmpty) return false;
    await Clipboard.setData(ClipboardData(text: text));
    return true;
  }
}
