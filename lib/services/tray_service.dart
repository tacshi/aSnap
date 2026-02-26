import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';

import '../utils/constants.dart';

class TrayService with TrayListener {
  VoidCallback? onCaptureFullScreen;
  VoidCallback? onCaptureRegion;
  VoidCallback? onCaptureScroll;
  VoidCallback? onPin;
  VoidCallback? onQuit;

  Future<void> init() async {
    await trayManager.setIcon(kTrayIconPath, isTemplate: true, iconSize: 18);
    await trayManager.setToolTip(kTrayTooltip);

    // Use tray_manager for menu creation and display (proper NSStatusItem
    // integration). On macOS, register shortcuts separately so the native
    // side can patch keyEquivalent on the menu items before they render.
    final menu = Menu(
      items: [
        MenuItem(key: 'capture_region', label: 'Region'),
        MenuItem(key: 'capture_scroll', label: 'Scroll'),
        MenuItem(key: 'capture_full_screen', label: 'Full Screen'),
        MenuItem.separator(),
        MenuItem(key: 'pin', label: 'Pin'),
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
      case 'pin':
        onPin?.call();
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
}
