import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../utils/file_naming.dart';

class FileService {
  /// Show native save dialog + write bytes in one step.
  /// Used by the preview screen where the window stays visible behind the sheet.
  Future<String?> saveScreenshot(Uint8List pngBytes) async {
    final savePath = await showSaveDialog();
    if (savePath != null) {
      return saveToPath(savePath, pngBytes);
    }
    return null;
  }

  /// Show the native save dialog and return the chosen path, or null if
  /// the user cancelled.  Does not write any bytes.
  Future<String?> showSaveDialog() async {
    final defaultName = generateScreenshotFileName();
    final downloadsDir = await getDownloadsDirectory();

    final location = await getSaveLocation(
      suggestedName: defaultName,
      initialDirectory: downloadsDir?.path,
      acceptedTypeGroups: [
        const XTypeGroup(label: 'PNG Images', extensions: ['png']),
      ],
    );
    return location?.path;
  }

  /// Write PNG bytes to a known path (no dialog).
  Future<String?> saveToPath(String path, Uint8List pngBytes) async {
    try {
      final file = File(path);
      await file.writeAsBytes(pngBytes);
      return path;
    } catch (e) {
      debugPrint('[aSnap] Failed to save screenshot to $path: $e');
      return null;
    }
  }
}
