import 'dart:ui';

import 'package:tray_manager/tray_manager.dart';

import '../utils/constants.dart';

class TrayService with TrayListener {
  VoidCallback? onCaptureFullScreen;
  VoidCallback? onCaptureRegion;
  VoidCallback? onQuit;

  Future<void> init() async {
    await trayManager.setIcon(kTrayIconPath, isTemplate: true);
    await trayManager.setToolTip(kTrayTooltip);

    final menu = Menu(
      items: [
        MenuItem(key: 'capture_full_screen', label: 'Capture Full Screen'),
        MenuItem(key: 'capture_region', label: 'Capture Region'),
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
