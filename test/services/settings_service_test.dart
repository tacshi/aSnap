import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:a_snap/models/shortcut_bindings.dart';
import 'package:a_snap/services/settings_service.dart';

Future<Directory> _tempDir() async {
  return Directory.systemTemp.createTemp('asnap_settings_test_');
}

Future<Map<String, dynamic>> _readSettings(Directory dir) async {
  final file = File('${dir.path}/settings.json');
  final raw = jsonDecode(await file.readAsString());
  return Map<String, dynamic>.from(raw as Map);
}

void main() {
  test('loads defaults when settings file is missing', () async {
    final dir = await _tempDir();
    final service = SettingsService(supportDirectoryProvider: () async => dir);

    final shortcuts = await service.loadShortcutBindings();
    final ocrPreview = await service.loadOcrPreviewEnabled();
    final ocrOpenUrlPrompt = await service.loadOcrOpenUrlPromptEnabled();

    expect(shortcuts.encodeJson(), ShortcutBindings.defaults().encodeJson());
    expect(ocrPreview, isFalse);
    expect(ocrOpenUrlPrompt, isTrue);
  });

  test('loads defaults when settings file lacks shortcuts', () async {
    final dir = await _tempDir();
    final file = File('${dir.path}/settings.json');
    await file.writeAsString(jsonEncode({'ocrPreviewEnabled': true}));
    final service = SettingsService(supportDirectoryProvider: () async => dir);

    final shortcuts = await service.loadShortcutBindings();
    final ocrPreview = await service.loadOcrPreviewEnabled();

    expect(shortcuts.encodeJson(), ShortcutBindings.defaults().encodeJson());
    expect(ocrPreview, isTrue);
  });

  test('persists OCR preview flag alongside shortcuts', () async {
    final dir = await _tempDir();
    final service = SettingsService(supportDirectoryProvider: () async => dir);
    final updated = ShortcutBindings.defaults().copyWithAction(
      ShortcutAction.region,
      ShortcutBindings.defaults().region,
    );

    await service.saveShortcutBindings(updated);
    await service.saveOcrPreviewEnabled(true);
    await service.saveOcrOpenUrlPromptEnabled(false);

    var map = await _readSettings(dir);
    expect(map['ocrPreviewEnabled'], isTrue);
    expect(map['ocrOpenUrlPromptEnabled'], isFalse);
    expect(map['shortcuts'], isA<Map>());

    await service.saveShortcutBindings(ShortcutBindings.defaults());

    map = await _readSettings(dir);
    expect(map['ocrPreviewEnabled'], isTrue);
    expect(map['ocrOpenUrlPromptEnabled'], isFalse);
  });
}
