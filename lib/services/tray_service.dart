import 'dart:ui';

import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:tray_manager/tray_manager.dart';

import '../utils/constants.dart';

class TrayService with TrayListener {
  VoidCallback? onCaptureFullScreen;
  VoidCallback? onCaptureRegion;
  VoidCallback? onCaptureScroll;
  VoidCallback? onQuit;

  Future<void> init() async {
    await trayManager.setIcon(kTrayIconPath, isTemplate: true);
    await trayManager.setToolTip(kTrayTooltip);

    final menu = Menu(
      items: [
        MenuItem(
          key: 'capture_full_screen',
          label: 'Full Screen (${_shortcutLabel(kFullScreenHotkey)})',
        ),
        MenuItem(
          key: 'capture_region',
          label: 'Region (${_shortcutLabel(kRegionHotkey)})',
        ),
        MenuItem(
          key: 'capture_scroll',
          label: 'Scroll (${_shortcutLabel(kScrollCaptureHotkey)})',
        ),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: 'Quit $kAppName'),
      ],
    );
    await trayManager.setContextMenu(menu);
    trayManager.addListener(this);
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'capture_full_screen':
        onCaptureFullScreen?.call();
      case 'capture_region':
        onCaptureRegion?.call();
      case 'capture_scroll':
        onCaptureScroll?.call();
      case 'quit':
        onQuit?.call();
    }
  }

  @override
  void onTrayIconMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  Future<void> destroy() async {
    trayManager.removeListener(this);
    await trayManager.destroy();
  }

  /// Compact shortcut label from a HotKey, e.g. "⌘⇧1".
  /// Uses keyLabel (symbol map) instead of debugName (raw key names).
  static String _shortcutLabel(HotKey hotKey) {
    final modifiers = (hotKey.modifiers ?? [])
        .map((m) => m.physicalKeys.first.keyLabel)
        .join();
    return '$modifiers${hotKey.physicalKey.keyLabel}';
  }
}
