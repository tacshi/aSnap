import 'dart:ui';

import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

class WindowService {
  static const _minPreviewSize = Size(400, 300);

  Future<void> ensureInitialized() async {
    await windowManager.ensureInitialized();
  }

  Future<void> hideOnReady() async {
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(200, 200),
        center: true,
        skipTaskbar: true,
        titleBarStyle: TitleBarStyle.hidden,
      ),
      () async {
        await windowManager.hide();
        await windowManager.setSkipTaskbar(true);
        await windowManager.setPreventClose(true);
      },
    );
  }

  Future<void> showPreview({
    required int imageWidth,
    required int imageHeight,
  }) async {
    if (imageWidth <= 0 || imageHeight <= 0) return;

    final display = await screenRetriever.getPrimaryDisplay();
    final screenSize = display.size;

    final maxW = screenSize.width * 0.8;
    final maxH = screenSize.height * 0.8;

    // Size window to image aspect ratio (toolbar floats over image)
    final imageAspect = imageWidth / imageHeight;
    var winW = imageWidth.toDouble();
    var winH = imageHeight.toDouble();

    if (winW > maxW) {
      winW = maxW;
      winH = winW / imageAspect;
    }
    if (winH > maxH) {
      winH = maxH;
      winW = winH * imageAspect;
    }

    winW = winW.clamp(_minPreviewSize.width, maxW);
    winH = winH.clamp(_minPreviewSize.height, maxH);

    final previewSize = Size(winW, winH);

    await windowManager.setMinimumSize(const Size(0, 0));
    await windowManager.setMaximumSize(
      Size(screenSize.width, screenSize.height),
    );
    await windowManager.setTitleBarStyle(
      TitleBarStyle.hidden,
      windowButtonVisibility: false,
    );
    await windowManager.setSize(previewSize);
    await windowManager.setMinimumSize(previewSize);
    await windowManager.setMaximumSize(previewSize);
    await windowManager.setAlwaysOnTop(true);
    await windowManager.setSkipTaskbar(true);
    await windowManager.setHasShadow(true);

    final x = (screenSize.width - previewSize.width) / 2;
    final y = (screenSize.height - previewSize.height) / 2;
    await windowManager.setPosition(Offset(x, y));

    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> hidePreview() async {
    await windowManager.hide();
    await windowManager.setAlwaysOnTop(false);
  }
}
