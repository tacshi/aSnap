import 'dart:io';

import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

const String kAppName = 'aSnap';
const String kTrayIconPath = 'assets/icons/tray_icon.png';
const String kTrayTooltip = 'aSnap - Screenshot Tool';

// Default hotkeys: Cmd+Shift+1/2 on macOS, Ctrl+Shift+1/2 on Windows
HotKey get kFullScreenHotkey => HotKey(
  key: PhysicalKeyboardKey.digit1,
  modifiers: Platform.isMacOS
      ? [HotKeyModifier.meta, HotKeyModifier.shift]
      : [HotKeyModifier.control, HotKeyModifier.shift],
  scope: HotKeyScope.system,
);

HotKey get kRegionHotkey => HotKey(
  key: PhysicalKeyboardKey.digit2,
  modifiers: Platform.isMacOS
      ? [HotKeyModifier.meta, HotKeyModifier.shift]
      : [HotKeyModifier.control, HotKeyModifier.shift],
  scope: HotKeyScope.system,
);
