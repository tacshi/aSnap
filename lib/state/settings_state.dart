import 'package:flutter/foundation.dart';

import '../models/shortcut_bindings.dart';
import '../services/hotkey_service.dart';
import '../services/settings_service.dart';
import '../services/tray_service.dart';
import '../services/window_service.dart';

class SettingsState extends ChangeNotifier {
  SettingsState({
    required ShortcutBindings initialShortcuts,
    required bool initialOcrPreviewEnabled,
    required bool initialOcrOpenUrlPromptEnabled,
    required SettingsService settingsService,
    required WindowService windowService,
    required HotkeyService hotkeyService,
    required TrayService trayService,
  }) : _shortcuts = initialShortcuts,
       _ocrPreviewEnabled = initialOcrPreviewEnabled,
       _ocrOpenUrlPromptEnabled = initialOcrOpenUrlPromptEnabled,
       _settingsService = settingsService,
       _windowService = windowService,
       _hotkeyService = hotkeyService,
       _trayService = trayService;

  final SettingsService _settingsService;
  final WindowService _windowService;
  final HotkeyService _hotkeyService;
  final TrayService _trayService;

  ShortcutBindings _shortcuts;
  ShortcutBindings get shortcuts => _shortcuts;

  bool _ocrPreviewEnabled = false;
  bool get ocrPreviewEnabled => _ocrPreviewEnabled;

  String? _ocrPreviewError;
  String? get ocrPreviewError => _ocrPreviewError;

  bool _ocrOpenUrlPromptEnabled = true;
  bool get ocrOpenUrlPromptEnabled => _ocrOpenUrlPromptEnabled;

  String? _ocrOpenUrlPromptError;
  String? get ocrOpenUrlPromptError => _ocrOpenUrlPromptError;

  bool _launchAtLoginSupported = false;
  bool get launchAtLoginSupported => _launchAtLoginSupported;

  bool _launchAtLoginEnabled = false;
  bool get launchAtLoginEnabled => _launchAtLoginEnabled;

  bool _launchAtLoginRequiresApproval = false;
  bool get launchAtLoginRequiresApproval => _launchAtLoginRequiresApproval;

  bool _launchAtLoginBusy = false;
  bool get launchAtLoginBusy => _launchAtLoginBusy;

  String? _launchAtLoginError;
  String? get launchAtLoginError => _launchAtLoginError;

  String? _shortcutError;
  String? get shortcutError => _shortcutError;

  Future<void> refreshLaunchAtLogin() async {
    _launchAtLoginBusy = true;
    _launchAtLoginError = null;
    notifyListeners();

    try {
      final state = await _windowService.getLaunchAtLoginState();
      _applyLaunchAtLoginState(state);
    } catch (error) {
      _launchAtLoginSupported = false;
      _launchAtLoginEnabled = false;
      _launchAtLoginRequiresApproval = false;
      _launchAtLoginError = error.toString();
    } finally {
      _launchAtLoginBusy = false;
      notifyListeners();
    }
  }

  Future<void> setLaunchAtLoginEnabled(bool enabled) async {
    _launchAtLoginBusy = true;
    _launchAtLoginError = null;
    notifyListeners();

    try {
      final state = await _windowService.setLaunchAtLoginEnabled(enabled);
      _applyLaunchAtLoginState(state);
    } catch (error) {
      _launchAtLoginError = error.toString();
    } finally {
      _launchAtLoginBusy = false;
      notifyListeners();
    }
  }

  Future<bool> applyShortcuts(ShortcutBindings shortcuts) async {
    final previousShortcuts = _shortcuts;
    var hotkeysUpdated = false;
    var trayUpdated = false;

    _shortcutError = null;
    notifyListeners();

    try {
      await _hotkeyService.updateBindings(shortcuts);
      hotkeysUpdated = true;
      await _trayService.updateShortcuts(shortcuts);
      trayUpdated = true;
      await _settingsService.saveShortcutBindings(shortcuts);
      _shortcuts = shortcuts;
      notifyListeners();
      return true;
    } catch (error) {
      if (trayUpdated) {
        try {
          await _trayService.updateShortcuts(previousShortcuts);
        } catch (_) {}
      }
      if (hotkeysUpdated) {
        try {
          await _hotkeyService.updateBindings(previousShortcuts);
        } catch (_) {}
      }
      _shortcutError = error.toString();
      notifyListeners();
      return false;
    }
  }

  void clearShortcutError() {
    if (_shortcutError == null) return;
    _shortcutError = null;
    notifyListeners();
  }

  Future<void> setOcrPreviewEnabled(bool enabled) async {
    if (_ocrPreviewEnabled == enabled) return;
    final previous = _ocrPreviewEnabled;
    _ocrPreviewEnabled = enabled;
    _ocrPreviewError = null;
    notifyListeners();

    try {
      await _settingsService.saveOcrPreviewEnabled(enabled);
    } catch (error) {
      _ocrPreviewEnabled = previous;
      _ocrPreviewError = error.toString();
      notifyListeners();
    }
  }

  void clearOcrPreviewError() {
    if (_ocrPreviewError == null) return;
    _ocrPreviewError = null;
    notifyListeners();
  }

  Future<void> setOcrOpenUrlPromptEnabled(bool enabled) async {
    if (_ocrOpenUrlPromptEnabled == enabled) return;
    final previous = _ocrOpenUrlPromptEnabled;
    _ocrOpenUrlPromptEnabled = enabled;
    _ocrOpenUrlPromptError = null;
    notifyListeners();

    try {
      await _settingsService.saveOcrOpenUrlPromptEnabled(enabled);
    } catch (error) {
      _ocrOpenUrlPromptEnabled = previous;
      _ocrOpenUrlPromptError = error.toString();
      notifyListeners();
    }
  }

  void clearOcrOpenUrlPromptError() {
    if (_ocrOpenUrlPromptError == null) return;
    _ocrOpenUrlPromptError = null;
    notifyListeners();
  }

  void _applyLaunchAtLoginState(LaunchAtLoginState state) {
    _launchAtLoginSupported = state.supported;
    _launchAtLoginEnabled = state.enabled;
    _launchAtLoginRequiresApproval = state.requiresApproval;
  }
}
