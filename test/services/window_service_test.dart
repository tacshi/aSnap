import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:a_snap/services/window_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.asnap/window');
  final windowService = WindowService();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('getLaunchAtLoginState falls back when plugin is unavailable', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw MissingPluginException();
        });

    final state = await windowService.getLaunchAtLoginState();

    expect(state.supported, isFalse);
    expect(state.enabled, isFalse);
    expect(state.requiresApproval, isFalse);
  });

  test(
    'setLaunchAtLoginEnabled falls back when plugin is unavailable',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            throw MissingPluginException();
          });

      final state = await windowService.setLaunchAtLoginEnabled(true);

      expect(state.supported, isFalse);
      expect(state.enabled, isFalse);
      expect(state.requiresApproval, isFalse);
    },
  );

  test('startRectPolling forwards includeAxChildren false by default', () async {
    MethodCall? capturedCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          capturedCall = call;
          return null;
        });

    await windowService.startRectPolling();

    expect(capturedCall?.method, 'startRectPolling');
    expect(capturedCall?.arguments, {'includeAxChildren': false});
  });

  test('startRectPolling forwards includeAxChildren true when requested', () async {
    MethodCall? capturedCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          capturedCall = call;
          return null;
        });

    await windowService.startRectPolling(includeAxChildren: true);

    expect(capturedCall?.method, 'startRectPolling');
    expect(capturedCall?.arguments, {'includeAxChildren': true});
  });
}
