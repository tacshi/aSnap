import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

import 'package:a_snap/models/shortcut_bindings.dart';
import 'package:a_snap/services/hotkey_service.dart';
import 'package:a_snap/services/settings_service.dart';
import 'package:a_snap/services/tray_service.dart';
import 'package:a_snap/services/window_service.dart';
import 'package:a_snap/state/settings_state.dart';

class _FakeSettingsService extends SettingsService {
  _FakeSettingsService() : super();

  bool failSave = false;
  bool failOcrSave = false;
  bool failOcrOpenUrlSave = false;
  ShortcutBindings? savedShortcuts;
  bool? savedOcrPreviewEnabled;
  bool? savedOcrOpenUrlPromptEnabled;

  @override
  Future<void> saveShortcutBindings(ShortcutBindings bindings) async {
    if (failSave) {
      throw Exception('save failed');
    }
    savedShortcuts = bindings;
  }

  @override
  Future<void> saveOcrPreviewEnabled(bool enabled) async {
    if (failOcrSave) {
      throw Exception('ocr save failed');
    }
    savedOcrPreviewEnabled = enabled;
  }

  @override
  Future<void> saveOcrOpenUrlPromptEnabled(bool enabled) async {
    if (failOcrOpenUrlSave) {
      throw Exception('ocr open url save failed');
    }
    savedOcrOpenUrlPromptEnabled = enabled;
  }
}

class _FakeWindowService extends WindowService {
  LaunchAtLoginState state = const LaunchAtLoginState(
    supported: false,
    enabled: false,
    requiresApproval: false,
  );

  @override
  Future<LaunchAtLoginState> getLaunchAtLoginState() async {
    return state;
  }
}

class _FakeHotkeyService extends HotkeyService {
  final List<ShortcutBindings> updates = [];
  bool failUpdate = false;

  @override
  Future<void> updateBindings(ShortcutBindings bindings) async {
    if (failUpdate) {
      throw Exception('hotkey update failed');
    }
    updates.add(bindings);
  }
}

class _FakeTrayService extends TrayService {
  final List<ShortcutBindings> updates = [];

  @override
  Future<void> updateShortcuts(ShortcutBindings shortcuts) async {
    updates.add(shortcuts);
  }
}

ShortcutBindings _updatedShortcuts() {
  return ShortcutBindings.defaults().copyWithAction(
    ShortcutAction.region,
    HotKey(
      key: PhysicalKeyboardKey.keyR,
      modifiers: const [HotKeyModifier.meta, HotKeyModifier.shift],
      scope: HotKeyScope.system,
    ),
  );
}

ShortcutBindings _ctrlBackedShortcuts() {
  return ShortcutBindings.defaults().copyWithAction(
    ShortcutAction.region,
    HotKey(
      key: PhysicalKeyboardKey.keyR,
      modifiers: const [
        HotKeyModifier.control,
        HotKeyModifier.meta,
        HotKeyModifier.shift,
      ],
      scope: HotKeyScope.system,
    ),
  );
}

void main() {
  late _FakeSettingsService settingsService;
  late _FakeWindowService windowService;
  late _FakeHotkeyService hotkeyService;
  late _FakeTrayService trayService;
  late SettingsState state;

  setUp(() {
    settingsService = _FakeSettingsService();
    windowService = _FakeWindowService();
    hotkeyService = _FakeHotkeyService();
    trayService = _FakeTrayService();
    state = SettingsState(
      initialShortcuts: ShortcutBindings.defaults(),
      initialOcrPreviewEnabled: false,
      initialOcrOpenUrlPromptEnabled: true,
      settingsService: settingsService,
      windowService: windowService,
      hotkeyService: hotkeyService,
      trayService: trayService,
    );
  });

  test('applyShortcuts persists successful changes', () async {
    final updated = _updatedShortcuts();

    final saved = await state.applyShortcuts(updated);

    expect(saved, isTrue);
    expect(state.shortcuts.encodeJson(), updated.encodeJson());
    expect(state.shortcutError, isNull);
    expect(settingsService.savedShortcuts?.encodeJson(), updated.encodeJson());
    expect(hotkeyService.updates, hasLength(1));
    expect(trayService.updates, hasLength(1));
    expect(hotkeyService.updates.single.encodeJson(), updated.encodeJson());
    expect(trayService.updates.single.encodeJson(), updated.encodeJson());
  });

  test('applyShortcuts persists Ctrl-backed shortcut updates', () async {
    final updated = _ctrlBackedShortcuts();

    final saved = await state.applyShortcuts(updated);

    expect(saved, isTrue);
    expect(state.shortcuts.encodeJson(), updated.encodeJson());
    expect(settingsService.savedShortcuts?.encodeJson(), updated.encodeJson());
    expect(hotkeyService.updates.single.encodeJson(), updated.encodeJson());
    expect(trayService.updates.single.encodeJson(), updated.encodeJson());
  });

  test('applyShortcuts rolls back runtime changes when save fails', () async {
    settingsService.failSave = true;
    final initial = state.shortcuts;
    final updated = _updatedShortcuts();

    final saved = await state.applyShortcuts(updated);

    expect(saved, isFalse);
    expect(state.shortcuts.encodeJson(), initial.encodeJson());
    expect(state.shortcutError, contains('save failed'));
    expect(settingsService.savedShortcuts, isNull);
    expect(hotkeyService.updates, hasLength(2));
    expect(trayService.updates, hasLength(2));
    expect(hotkeyService.updates.first.encodeJson(), updated.encodeJson());
    expect(hotkeyService.updates.last.encodeJson(), initial.encodeJson());
    expect(trayService.updates.first.encodeJson(), updated.encodeJson());
    expect(trayService.updates.last.encodeJson(), initial.encodeJson());
  });

  test(
    'applyShortcuts stops before persistence when hotkey update fails',
    () async {
      hotkeyService.failUpdate = true;
      final initial = state.shortcuts;
      final updated = _updatedShortcuts();

      final saved = await state.applyShortcuts(updated);

      expect(saved, isFalse);
      expect(state.shortcuts.encodeJson(), initial.encodeJson());
      expect(state.shortcutError, contains('hotkey update failed'));
      expect(settingsService.savedShortcuts, isNull);
      expect(hotkeyService.updates, isEmpty);
      expect(trayService.updates, isEmpty);
    },
  );

  test('refreshLaunchAtLogin loads the native state', () async {
    windowService.state = const LaunchAtLoginState(
      supported: true,
      enabled: true,
      requiresApproval: true,
    );

    await state.refreshLaunchAtLogin();

    expect(state.launchAtLoginSupported, isTrue);
    expect(state.launchAtLoginEnabled, isTrue);
    expect(state.launchAtLoginRequiresApproval, isTrue);
    expect(state.launchAtLoginBusy, isFalse);
    expect(state.launchAtLoginError, isNull);
  });

  test('setOcrPreviewEnabled persists the setting', () async {
    await state.setOcrPreviewEnabled(true);

    expect(state.ocrPreviewEnabled, isTrue);
    expect(settingsService.savedOcrPreviewEnabled, isTrue);
    expect(state.ocrPreviewError, isNull);
  });

  test('setOcrPreviewEnabled rolls back on save failure', () async {
    settingsService.failOcrSave = true;

    await state.setOcrPreviewEnabled(true);

    expect(state.ocrPreviewEnabled, isFalse);
    expect(state.ocrPreviewError, contains('ocr save failed'));
  });

  test('setOcrOpenUrlPromptEnabled persists the setting', () async {
    await state.setOcrOpenUrlPromptEnabled(false);

    expect(state.ocrOpenUrlPromptEnabled, isFalse);
    expect(settingsService.savedOcrOpenUrlPromptEnabled, isFalse);
    expect(state.ocrOpenUrlPromptError, isNull);
  });

  test('setOcrOpenUrlPromptEnabled rolls back on save failure', () async {
    settingsService.failOcrOpenUrlSave = true;

    await state.setOcrOpenUrlPromptEnabled(false);

    expect(state.ocrOpenUrlPromptEnabled, isTrue);
    expect(state.ocrOpenUrlPromptError, contains('ocr open url save failed'));
  });
}
