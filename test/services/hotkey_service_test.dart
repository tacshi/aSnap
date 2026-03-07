import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

import 'package:a_snap/models/shortcut_bindings.dart';
import 'package:a_snap/services/hotkey_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const nativeHotkeyChannel = MethodChannel('com.asnap/hotkeys');
  final nativeCalls = <MethodCall>[];
  var failNativeRegistration = false;

  ShortcutBindings bindingsWithRegionShortcut({
    required PhysicalKeyboardKey key,
    required List<HotKeyModifier> modifiers,
  }) {
    return ShortcutBindings.defaults().copyWithAction(
      ShortcutAction.region,
      HotKey(
        identifier: ShortcutAction.region.id,
        key: key,
        modifiers: modifiers,
        scope: HotKeyScope.system,
      ),
    );
  }

  List<Map<String, dynamic>> registeredDescriptors(MethodCall call) {
    final items = (call.arguments as List<dynamic>)
        .cast<Map<dynamic, dynamic>>();
    return items
        .map((item) => Map<String, dynamic>.from(item))
        .toList(growable: false);
  }

  setUp(() {
    nativeCalls.clear();
    failNativeRegistration = false;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativeHotkeyChannel, (call) async {
          nativeCalls.add(call);

          if (call.method == 'setHotkeys' && failNativeRegistration) {
            throw PlatformException(
              code: 'register_failed',
              message: 'native rejected shortcut registration',
            );
          }

          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativeHotkeyChannel, null);
  });

  test(
    'registers Ctrl-based shortcuts through the native macOS channel',
    () async {
      final service = HotkeyService();

      await service.initialize(
        bindings: bindingsWithRegionShortcut(
          key: PhysicalKeyboardKey.keyR,
          modifiers: const [HotKeyModifier.control, HotKeyModifier.shift],
        ),
        onFullScreen: () {},
        onRegion: () {},
        onScrollCapture: () {},
        onPin: () {},
      );

      addTearDown(service.unregisterAll);

      final setHotkeysCall = nativeCalls.singleWhere(
        (call) => call.method == 'setHotkeys',
      );
      final regionDescriptor = registeredDescriptors(
        setHotkeysCall,
      ).singleWhere((item) => item['action'] == ShortcutAction.region.name);

      expect(regionDescriptor['modifiers'], ['control', 'shift']);
      expect(regionDescriptor['keyCode'], 0x0000000f);
    },
    skip: !Platform.isMacOS,
  );

  test(
    'registers mixed Ctrl+Cmd shortcuts through the native macOS channel',
    () async {
      final service = HotkeyService();

      await service.initialize(
        bindings: bindingsWithRegionShortcut(
          key: PhysicalKeyboardKey.keyA,
          modifiers: const [
            HotKeyModifier.control,
            HotKeyModifier.meta,
            HotKeyModifier.shift,
          ],
        ),
        onFullScreen: () {},
        onRegion: () {},
        onScrollCapture: () {},
        onPin: () {},
      );

      addTearDown(service.unregisterAll);

      final setHotkeysCall = nativeCalls.singleWhere(
        (call) => call.method == 'setHotkeys',
      );
      final regionDescriptor = registeredDescriptors(
        setHotkeysCall,
      ).singleWhere((item) => item['action'] == ShortcutAction.region.name);

      expect(regionDescriptor['modifiers'], ['control', 'meta', 'shift']);
    },
    skip: !Platform.isMacOS,
  );

  test(
    'registers function key shortcuts through the native macOS channel',
    () async {
      final service = HotkeyService();

      await service.initialize(
        bindings: bindingsWithRegionShortcut(
          key: PhysicalKeyboardKey.f12,
          modifiers: const [HotKeyModifier.control, HotKeyModifier.shift],
        ),
        onFullScreen: () {},
        onRegion: () {},
        onScrollCapture: () {},
        onPin: () {},
      );

      addTearDown(service.unregisterAll);

      final setHotkeysCall = nativeCalls.singleWhere(
        (call) => call.method == 'setHotkeys',
      );
      final regionDescriptor = registeredDescriptors(
        setHotkeysCall,
      ).singleWhere((item) => item['action'] == ShortcutAction.region.name);

      expect(regionDescriptor['keyCode'], 0x0000006f);
    },
    skip: !Platform.isMacOS,
  );

  test(
    'fails when native macOS registration rejects a Ctrl shortcut',
    () async {
      final service = HotkeyService();
      failNativeRegistration = true;

      expect(
        () => service.initialize(
          bindings: bindingsWithRegionShortcut(
            key: PhysicalKeyboardKey.keyR,
            modifiers: const [HotKeyModifier.control, HotKeyModifier.shift],
          ),
          onFullScreen: () {},
          onRegion: () {},
          onScrollCapture: () {},
          onPin: () {},
        ),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            'message',
            contains('native rejected shortcut registration'),
          ),
        ),
      );
    },
    skip: !Platform.isMacOS,
  );

  test(
    'native macOS hotkey callbacks dispatch the expected action',
    () async {
      final service = HotkeyService();
      var regionTriggered = 0;
      var fullScreenTriggered = 0;

      await service.initialize(
        bindings: ShortcutBindings.defaults(),
        onFullScreen: () {
          fullScreenTriggered += 1;
        },
        onRegion: () {
          regionTriggered += 1;
        },
        onScrollCapture: () {},
        onPin: () {},
      );

      addTearDown(service.unregisterAll);

      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      await messenger.handlePlatformMessage(
        nativeHotkeyChannel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('onShortcutTriggered', {'action': 'region'}),
        ),
        (_) {},
      );

      expect(regionTriggered, 1);
      expect(fullScreenTriggered, 0);
    },
    skip: !Platform.isMacOS,
  );

  test(
    'suspend and resume re-register the latest shortcuts natively',
    () async {
      final service = HotkeyService();
      final updatedBindings = bindingsWithRegionShortcut(
        key: PhysicalKeyboardKey.keyR,
        modifiers: const [HotKeyModifier.control, HotKeyModifier.shift],
      );

      await service.initialize(
        bindings: ShortcutBindings.defaults(),
        onFullScreen: () {},
        onRegion: () {},
        onScrollCapture: () {},
        onPin: () {},
      );

      addTearDown(service.unregisterAll);

      final setHotkeysBeforeSuspend = nativeCalls
          .where((call) => call.method == 'setHotkeys')
          .length;
      await service.suspend();
      final callsAfterSuspend = nativeCalls.length;

      await service.updateBindings(updatedBindings);
      expect(nativeCalls.length, callsAfterSuspend);

      await service.resume();

      final setHotkeysCalls = nativeCalls
          .where((call) => call.method == 'setHotkeys')
          .toList(growable: false);
      expect(setHotkeysCalls.length, greaterThan(setHotkeysBeforeSuspend));

      final regionDescriptor = registeredDescriptors(
        setHotkeysCalls.last,
      ).singleWhere((item) => item['action'] == ShortcutAction.region.name);
      expect(regionDescriptor['modifiers'], ['control', 'shift']);
    },
    skip: !Platform.isMacOS,
  );
}
