import 'package:flutter/material.dart';

import 'screens/preview_screen.dart';
import 'screens/region_selection_screen.dart';
import 'screens/scroll_result_screen.dart';
import 'services/window_service.dart';
import 'state/annotation_state.dart';
import 'state/app_state.dart';
import 'widgets/scroll_progress_badge.dart';

class ASnapApp extends StatelessWidget {
  final AppState appState;
  final AnnotationState annotationState;
  final WindowService windowService;
  final VoidCallback onCopy;
  final VoidCallback onSave;
  final VoidCallback? onPin;
  final VoidCallback onDiscard;
  final void Function(Rect selectionRect) onRegionSelected;

  /// Snipaste-style overlay actions for region capture.
  final void Function(Rect selectionRect)? onRegionCopy;
  final void Function(Rect selectionRect)? onRegionSave;
  final void Function(Rect selectionRect)? onRegionPin;

  final void Function(Rect selectionRect)? onScrollRegionSelected;
  final VoidCallback onRegionCancel;
  final Future<Rect?> Function(Offset localPoint)? onHitTest;
  final VoidCallback? onScrollCaptureDone;
  final void Function(Rect cgRect)? onScrollStopButtonRect;
  const ASnapApp({
    super.key,
    required this.appState,
    required this.annotationState,
    required this.windowService,
    required this.onCopy,
    required this.onSave,
    this.onPin,
    required this.onDiscard,
    required this.onRegionSelected,
    this.onRegionCopy,
    this.onRegionSave,
    this.onRegionPin,
    this.onScrollRegionSelected,
    required this.onRegionCancel,
    this.onHitTest,
    this.onScrollCaptureDone,
    this.onScrollStopButtonRect,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'aSnap',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        // Transparent canvas so the rainbow border overlay renders correctly
        // on the transparent NSWindow. Other screens (preview, region selection)
        // have opaque NSWindow backgrounds that show through.
        canvasColor: Colors.transparent,
        scaffoldBackgroundColor: Colors.transparent,
      ),
      home: ListenableBuilder(
        listenable: appState,
        builder: (context, _) {
          switch (appState.workflow) {
            case RegionSelectionWorkflow(
              :final decodedImage,
              :final windowRects,
              isScrollSelection: false,
            ):
              return RegionSelectionScreen(
                decodedImage: decodedImage,
                windowRects: windowRects,
                onCancel: onRegionCancel,
                windowService: windowService,
                onCopy: onRegionCopy,
                onSave: onRegionSave,
                onPin: onRegionPin,
                onHitTest: onHitTest,
                annotationState: annotationState,
              );
            case RegionSelectionWorkflow(
              :final decodedImage,
              :final windowRects,
              isScrollSelection: true,
            ):
              return RegionSelectionScreen(
                decodedImage: decodedImage,
                windowRects: windowRects,
                onCancel: onRegionCancel,
                windowService: windowService,
                onRegionSelected: onScrollRegionSelected ?? onRegionSelected,
                onHitTest: onHitTest,
                isScrollSelection: true,
              );
            case ScrollCapturingWorkflow(
              :final frameCount,
              :final previewImage,
              :final captureRegion,
              :final screenOrigin,
              :final screenSize,
            ):
              return ScrollCapturePreview(
                frameCount: frameCount,
                previewImage: previewImage,
                captureRegion: captureRegion,
                screenOrigin: screenOrigin,
                screenSize: screenSize,
                onDone: onScrollCaptureDone,
                onStopButtonRect: onScrollStopButtonRect,
              );
            case ScrollResultWorkflow(:final image):
              return ScrollResultScreen(
                stitchedImage: image,
                annotationState: annotationState,
                windowService: windowService,
                onCopy: onCopy,
                onSave: onSave,
                onDiscard: onDiscard,
              );
            default:
              break;
          }
          return PreviewScreen(
            appState: appState,
            annotationState: annotationState,
            windowService: windowService,
            onCopy: onCopy,
            onSave: onSave,
            onPin: onPin,
            onDiscard: onDiscard,
          );
        },
      ),
    );
  }
}
