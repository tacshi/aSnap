import 'dart:io';

import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

import '../models/shortcut_bindings.dart';
import '../utils/macos_key_codes.dart';

class HotkeyService {
  static const _dedupeWindow = Duration(milliseconds: 150);
  static const _nativeChannel = MethodChannel('com.asnap/hotkeys');

  bool _enabled = true;
  ShortcutBindings _bindings = ShortcutBindings.defaults();
  final Map<ShortcutAction, DateTime> _lastTriggeredAt = {};
  bool _nativeChannelBound = false;

  VoidCallback? _onFullScreen;
  VoidCallback? _onRegion;
  VoidCallback? _onScrollCapture;
  VoidCallback? _onPin;

  Future<void> initialize({
    required ShortcutBindings bindings,
    required VoidCallback onFullScreen,
    required VoidCallback onRegion,
    required VoidCallback onScrollCapture,
    required VoidCallback onPin,
  }) async {
    _bindings = bindings;
    _onFullScreen = onFullScreen;
    _onRegion = onRegion;
    _onScrollCapture = onScrollCapture;
    _onPin = onPin;
    _enabled = true;
    _bindNativeChannel();
    await _registerCurrentBindings();
  }

  Future<void> updateBindings(ShortcutBindings bindings) async {
    final previousBindings = _bindings;
    _bindings = bindings;
    if (!_enabled) return;
    try {
      await _registerCurrentBindings();
    } catch (_) {
      _bindings = previousBindings;
      await _registerCurrentBindings();
      rethrow;
    }
  }

  Future<void> suspend() async {
    _enabled = false;
    await unregisterAll();
  }

  Future<void> resume() async {
    _enabled = true;
    await _registerCurrentBindings();
  }

  Future<void> unregisterAll() async {
    if (Platform.isMacOS) {
      await _nativeChannel.invokeMethod('unregisterAll');
      return;
    }
    await hotKeyManager.unregisterAll();
  }

  Future<void> _registerCurrentBindings() async {
    final onFullScreen = _onFullScreen;
    final onRegion = _onRegion;
    final onScrollCapture = _onScrollCapture;
    final onPin = _onPin;

    if (onFullScreen == null ||
        onRegion == null ||
        onScrollCapture == null ||
        onPin == null) {
      return;
    }

    if (Platform.isMacOS) {
      await _registerNativeBindings();
      return;
    }

    await hotKeyManager.unregisterAll();

    try {
      for (final entry in _bindings.entries) {
        try {
          await hotKeyManager.register(
            entry.value,
            keyDownHandler: (_) => _dispatchAction(entry.key),
          );
        } catch (error) {
          throw Exception(
            'Failed to register ${entry.key.name} shortcut: $error',
          );
        }
      }
    } catch (_) {
      await hotKeyManager.unregisterAll();
      rethrow;
    }
  }

  void _bindNativeChannel() {
    if (!Platform.isMacOS || _nativeChannelBound) return;
    _nativeChannel.setMethodCallHandler(_handleNativeMethodCall);
    _nativeChannelBound = true;
  }

  Future<void> _registerNativeBindings() async {
    final descriptors = _bindings.entries
        .map((entry) => _nativeShortcutDescriptor(entry.key, entry.value))
        .toList(growable: false);

    try {
      await _nativeChannel.invokeMethod('setHotkeys', descriptors);
    } on PlatformException catch (error) {
      final message = error.message ?? error.code;
      throw Exception('Failed to register shortcuts: $message');
    } catch (error) {
      throw Exception('Failed to register shortcuts: $error');
    }
  }

  Future<void> _handleNativeMethodCall(MethodCall call) async {
    if (call.method != 'onShortcutTriggered') {
      return;
    }

    final rawArguments = call.arguments;
    if (rawArguments is! Map) {
      return;
    }

    final actionName = rawArguments['action'] as String?;
    final action = _actionFromName(actionName);
    if (action == null) {
      return;
    }

    _dispatchAction(action);
  }

  Map<String, Object?> _nativeShortcutDescriptor(
    ShortcutAction action,
    HotKey hotKey,
  ) {
    final keyCode = macOsKeyCodeForPhysicalKey(hotKey.physicalKey);
    if (keyCode == null) {
      throw Exception('Failed to encode ${action.name} shortcut key code.');
    }

    return {
      'action': action.name,
      'identifier': action.id,
      'keyCode': keyCode,
      'modifiers': [...?hotKey.modifiers?.map((modifier) => modifier.name)],
    };
  }

  ShortcutAction? _actionFromName(String? name) {
    if (name == null) return null;
    for (final action in ShortcutAction.values) {
      if (action.name == name) {
        return action;
      }
    }
    return null;
  }

  void _dispatchAction(ShortcutAction action) {
    final now = DateTime.now();
    final lastTriggeredAt = _lastTriggeredAt[action];
    if (lastTriggeredAt != null &&
        now.difference(lastTriggeredAt) < _dedupeWindow) {
      return;
    }
    _lastTriggeredAt[action] = now;

    switch (action) {
      case ShortcutAction.region:
        _onRegion?.call();
      case ShortcutAction.scrollCapture:
        _onScrollCapture?.call();
      case ShortcutAction.fullScreen:
        _onFullScreen?.call();
      case ShortcutAction.pin:
        _onPin?.call();
    }
  }
}
