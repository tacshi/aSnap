import 'dart:io';

import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

const String kAppName = 'aSnap';
const String kTrayIconPath = 'assets/icons/tray_icon.png';
const String kTrayTooltip = 'aSnap - Screenshot Tool';

// Default hotkeys: Cmd+Shift+1/2/3 on macOS, Ctrl+Shift+1/2/3 on Windows
HotKey get kRegionHotkey => HotKey(
  key: PhysicalKeyboardKey.digit1,
  modifiers: Platform.isMacOS
      ? [HotKeyModifier.meta, HotKeyModifier.shift]
      : [HotKeyModifier.control, HotKeyModifier.shift],
  scope: HotKeyScope.system,
);

HotKey get kScrollCaptureHotkey => HotKey(
  key: PhysicalKeyboardKey.digit2,
  modifiers: Platform.isMacOS
      ? [HotKeyModifier.meta, HotKeyModifier.shift]
      : [HotKeyModifier.control, HotKeyModifier.shift],
  scope: HotKeyScope.system,
);

HotKey get kFullScreenHotkey => HotKey(
  key: PhysicalKeyboardKey.digit3,
  modifiers: Platform.isMacOS
      ? [HotKeyModifier.meta, HotKeyModifier.shift]
      : [HotKeyModifier.control, HotKeyModifier.shift],
  scope: HotKeyScope.system,
);

// Scroll capture tuning constants
const int kScrollMaxFrames = 150;
const int kScrollTimeoutSeconds = 30;
const int kScrollCaptureFps = 15;
