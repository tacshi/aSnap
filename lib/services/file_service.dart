import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../utils/file_naming.dart';

class FileService {
  Future<String?> saveScreenshot(Uint8List pngBytes) async {
    final defaultName = generateScreenshotFileName();
    final downloadsDir = await getDownloadsDirectory();

    final location = await getSaveLocation(
      suggestedName: defaultName,
      initialDirectory: downloadsDir?.path,
      acceptedTypeGroups: [
        const XTypeGroup(label: 'PNG Images', extensions: ['png']),
      ],
    );

    if (location != null) {
      try {
        final file = File(location.path);
        await file.writeAsBytes(pngBytes);
        return location.path;
      } catch (e) {
        debugPrint('[aSnap] Failed to save screenshot to ${location.path}: $e');
        return null;
      }
    }
    return null;
  }
}
