import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/shortcut_bindings.dart';

class SettingsService {
  SettingsService({Future<Directory> Function()? supportDirectoryProvider})
    : _supportDirectoryProvider =
          supportDirectoryProvider ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _supportDirectoryProvider;

  Future<ShortcutBindings> loadShortcutBindings() async {
    try {
      final map = await _readSettingsMap();
      final shortcuts = map['shortcuts'];
      if (shortcuts is Map<String, dynamic>) {
        return ShortcutBindings.fromJson(shortcuts);
      }
      if (shortcuts is Map) {
        return ShortcutBindings.fromJson(Map<String, dynamic>.from(shortcuts));
      }
      return ShortcutBindings.defaults();
    } catch (_) {
      return ShortcutBindings.defaults();
    }
  }

  Future<void> saveShortcutBindings(ShortcutBindings bindings) async {
    final map = await _readSettingsMap();
    final next = _normalizeSettingsMap(map);
    next['shortcuts'] = bindings.toJson();
    await _writeSettingsMap(next);
  }

  Future<bool> loadOcrPreviewEnabled() async {
    try {
      final map = await _readSettingsMap();
      final value = map['ocrPreviewEnabled'];
      if (value is bool) return value;
    } catch (_) {}
    return false;
  }

  Future<void> saveOcrPreviewEnabled(bool enabled) async {
    final map = await _readSettingsMap();
    final next = _normalizeSettingsMap(map);
    next['ocrPreviewEnabled'] = enabled;
    await _writeSettingsMap(next);
  }

  Future<bool> loadOcrOpenUrlPromptEnabled() async {
    try {
      final map = await _readSettingsMap();
      final value = map['ocrOpenUrlPromptEnabled'];
      if (value is bool) return value;
    } catch (_) {}
    return true;
  }

  Future<void> saveOcrOpenUrlPromptEnabled(bool enabled) async {
    final map = await _readSettingsMap();
    final next = _normalizeSettingsMap(map);
    next['ocrOpenUrlPromptEnabled'] = enabled;
    await _writeSettingsMap(next);
  }

  Future<File> _settingsFile() async {
    final directory = await _supportDirectoryProvider();
    return File('${directory.path}/settings.json');
  }

  Map<String, dynamic> _normalizeSettingsMap(Map<String, dynamic> map) {
    if (map.containsKey('shortcuts') ||
        map.containsKey('ocrPreviewEnabled') ||
        map.containsKey('ocrOpenUrlPromptEnabled')) {
      return {...map};
    }
    return {};
  }

  Future<Map<String, dynamic>> _readSettingsMap() async {
    final file = await _settingsFile();
    if (!await file.exists()) {
      return {};
    }
    final raw = jsonDecode(await file.readAsString());
    if (raw is Map<String, dynamic>) {
      return raw;
    }
    if (raw is Map) {
      return Map<String, dynamic>.from(raw);
    }
    return {};
  }

  Future<void> _writeSettingsMap(Map<String, dynamic> map) async {
    final file = await _settingsFile();
    await file.parent.create(recursive: true);
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(map));
  }
}
