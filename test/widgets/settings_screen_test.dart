import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

import 'package:a_snap/models/shortcut_bindings.dart';
import 'package:a_snap/screens/settings_screen.dart';
import 'package:a_snap/services/hotkey_service.dart';
import 'package:a_snap/services/settings_service.dart';
import 'package:a_snap/services/tray_service.dart';
import 'package:a_snap/services/window_service.dart';
import 'package:a_snap/state/settings_state.dart';

class _FakeSettingsService extends SettingsService {
  _FakeSettingsService() : super();

  ShortcutBindings? savedShortcuts;
  bool? savedOcrPreviewEnabled;
  bool? savedOcrOpenUrlPromptEnabled;

  @override
  Future<void> saveShortcutBindings(ShortcutBindings bindings) async {
    savedShortcuts = bindings;
  }

  @override
  Future<void> saveOcrPreviewEnabled(bool enabled) async {
    savedOcrPreviewEnabled = enabled;
  }

  @override
  Future<void> saveOcrOpenUrlPromptEnabled(bool enabled) async {
    savedOcrOpenUrlPromptEnabled = enabled;
  }
}

class _FakeWindowService extends WindowService {}

class _FakeHotkeyService extends HotkeyService {
  final List<ShortcutBindings> updates = [];

  @override
  Future<void> updateBindings(ShortcutBindings bindings) async {
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

class _SettingsHarness {
  _SettingsHarness({
    required this.state,
    required this.settingsService,
    required this.hotkeyService,
    required this.trayService,
  });

  final SettingsState state;
  final _FakeSettingsService settingsService;
  final _FakeHotkeyService hotkeyService;
  final _FakeTrayService trayService;
}

ShortcutBindings _customShortcuts() {
  final primaryModifier = Platform.isMacOS
      ? HotKeyModifier.meta
      : HotKeyModifier.control;
  return ShortcutBindings.defaults().copyWithAction(
    ShortcutAction.region,
    HotKey(
      identifier: ShortcutAction.region.id,
      key: PhysicalKeyboardKey.keyR,
      modifiers: [primaryModifier, HotKeyModifier.shift],
      scope: HotKeyScope.system,
    ),
  );
}

Future<_SettingsHarness> _pumpSettingsScreen(
  WidgetTester tester, {
  ShortcutBindings? initialShortcuts,
}) async {
  final settingsService = _FakeSettingsService();
  final hotkeyService = _FakeHotkeyService();
  final trayService = _FakeTrayService();
  final state = SettingsState(
    initialShortcuts: initialShortcuts ?? ShortcutBindings.defaults(),
    initialOcrPreviewEnabled: false,
    initialOcrOpenUrlPromptEnabled: true,
    settingsService: settingsService,
    windowService: _FakeWindowService(),
    hotkeyService: hotkeyService,
    trayService: trayService,
  );

  await tester.binding.setSurfaceSize(const Size(900, 620));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(
    MaterialApp(
      home: SettingsScreen(
        settingsState: state,
        onClose: () async {},
        onSuspendHotkeys: () async {},
        onResumeHotkeys: () async {},
      ),
    ),
  );
  await tester.pumpAndSettle();

  return _SettingsHarness(
    state: state,
    settingsService: settingsService,
    hotkeyService: hotkeyService,
    trayService: trayService,
  );
}

void main() {
  const shortcutRecorderChannel = MethodChannel('com.asnap/shortcutRecorder');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(shortcutRecorderChannel, (call) async {
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(shortcutRecorderChannel, null);
  });

  testWidgets('settings screen renders as a simple list', (tester) async {
    await _pumpSettingsScreen(tester);

    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('General'), findsOneWidget);
    expect(find.text('Shortcuts'), findsOneWidget);
    expect(find.text('Launch at login'), findsOneWidget);
    expect(find.text('Show OCR preview'), findsOneWidget);
    expect(find.text('Prompt to open URL after OCR'), findsOneWidget);
    expect(find.text('Region'), findsOneWidget);
    expect(find.text('Scroll'), findsOneWidget);
    expect(find.text('Full Screen'), findsOneWidget);
    expect(find.text('Pin'), findsOneWidget);
    expect(find.text('OCR'), findsOneWidget);
    expect(find.text('Save changes'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shortcut rows render directly without extra navigation', (
    tester,
  ) async {
    await _pumpSettingsScreen(tester);

    expect(find.byType(OutlinedButton), findsNWidgets(5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('reset shortcut saves immediately', (tester) async {
    final harness = await _pumpSettingsScreen(
      tester,
      initialShortcuts: _customShortcuts(),
    );

    await tester.tap(find.byTooltip('Reset'));
    await tester.pumpAndSettle();

    expect(
      harness.state.shortcuts.encodeJson(),
      ShortcutBindings.defaults().encodeJson(),
    );
    expect(
      harness.settingsService.savedShortcuts?.encodeJson(),
      ShortcutBindings.defaults().encodeJson(),
    );
    expect(harness.hotkeyService.updates, hasLength(1));
    expect(harness.trayService.updates, hasLength(1));
  });

  testWidgets('shortcut recorder previews Ctrl and mixed modifier chords', (
    tester,
  ) async {
    final harness = await _pumpSettingsScreen(tester);

    final changeButton = find.byType(OutlinedButton).first;
    await tester.ensureVisible(changeButton);
    await tester.tap(changeButton, warnIfMissed: false);
    await tester.pumpAndSettle();

    if (Platform.isMacOS) {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      await messenger.handlePlatformMessage(
        shortcutRecorderChannel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('onShortcutRecorderChanged', {
            'modifiers': ['control'],
          }),
        ),
        (_) {},
      );
      await tester.pump();
    } else {
      await tester.sendKeyDownEvent(
        LogicalKeyboardKey.controlLeft,
        physicalKey: PhysicalKeyboardKey.controlLeft,
      );
      await tester.pump();
    }

    final dialogFinder = find.byType(Dialog);
    expect(
      find.descendant(of: dialogFinder, matching: find.text('Ctrl')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dialogFinder, matching: find.text('...')),
      findsOneWidget,
    );

    if (Platform.isMacOS) {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      await messenger.handlePlatformMessage(
        shortcutRecorderChannel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('onShortcutRecorderCaptured', {
            'keyCode': 0,
            'modifiers': ['control', 'meta'],
          }),
        ),
        (_) {},
      );
      await tester.pumpAndSettle();
    } else {
      await tester.sendKeyDownEvent(
        LogicalKeyboardKey.metaLeft,
        physicalKey: PhysicalKeyboardKey.metaLeft,
      );
      await tester.pump();
      await tester.sendKeyDownEvent(
        LogicalKeyboardKey.keyA,
        physicalKey: PhysicalKeyboardKey.keyA,
      );
      await tester.pumpAndSettle();
    }

    expect(
      find.descendant(of: dialogFinder, matching: find.text('Ctrl')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: dialogFinder,
        matching: find.text(Platform.isMacOS ? 'Cmd' : 'Meta'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dialogFinder, matching: find.text('A')),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Use Shortcut'));
    await tester.pumpAndSettle();

    expect(harness.settingsService.savedShortcuts, isNotNull);
    expect(harness.hotkeyService.updates, hasLength(1));
    expect(harness.trayService.updates, hasLength(1));
    final savedShortcutLabel = shortcutDisplayLabel(
      HotKey(
        key: PhysicalKeyboardKey.keyA,
        modifiers: const [HotKeyModifier.control, HotKeyModifier.meta],
        scope: HotKeyScope.system,
      ),
    );
    expect(find.text(savedShortcutLabel), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
