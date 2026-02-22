import 'package:flutter/material.dart';

import 'screens/preview_screen.dart';
import 'screens/region_selection_screen.dart';
import 'state/app_state.dart';
import 'utils/constants.dart';
import 'widgets/scroll_progress_badge.dart';

class ASnapApp extends StatelessWidget {
  final AppState appState;
  final VoidCallback onCopy;
  final VoidCallback onSave;
  final VoidCallback onDiscard;
  final void Function(Rect selectionRect) onRegionSelected;
  final VoidCallback onRegionCancel;
  final Future<Rect?> Function(Offset localPoint)? onHitTest;
  final VoidCallback? onScrollCancel;

  const ASnapApp({
    super.key,
    required this.appState,
    required this.onCopy,
    required this.onSave,
    required this.onDiscard,
    required this.onRegionSelected,
    required this.onRegionCancel,
    this.onHitTest,
    this.onScrollCancel,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'aSnap',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: ListenableBuilder(
        listenable: appState,
        builder: (context, _) {
          if (appState.status == CaptureStatus.selecting &&
              appState.decodedFullScreen != null) {
            return RegionSelectionScreen(
              decodedImage: appState.decodedFullScreen!,
              windowRects: appState.windowRects ?? const [],
              onCancel: onRegionCancel,
              onRegionSelected: onRegionSelected,
              onHitTest: onHitTest,
            );
          }
          if (appState.status == CaptureStatus.scrollCapturing) {
            return ScrollProgressBadge(
              frameCount: appState.scrollFrameCount,
              maxFrames: kScrollMaxFrames,
              onCancel: onScrollCancel ?? () {},
            );
          }
          return PreviewScreen(
            appState: appState,
            onCopy: onCopy,
            onSave: onSave,
            onDiscard: onDiscard,
          );
        },
      ),
    );
  }
}
