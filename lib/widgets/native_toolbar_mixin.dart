import 'dart:async';

import 'package:flutter/widgets.dart';

import '../services/window_service.dart';
import '../state/annotation_state.dart';
import '../utils/toolbar_actions.dart';
import 'tool_popover_mixin.dart';

/// Shared macOS native toolbar wiring for screens that expose annotation tools.
///
/// Dart owns the toolbar state and business logic, while AppKit renders the
/// actual floating panel. This mixin keeps action routing and sync behavior
/// identical across preview, region-selection, and scroll-result flows.
mixin NativeToolbarMixin<T extends StatefulWidget>
    on State<T>, ToolPopoverMixin<T> {
  Rect? _lastToolbarRect;
  bool _lastShowPin = false;
  bool _lastShowHistoryControls = false;
  bool _lastCanUndo = false;
  bool _lastCanRedo = false;
  String? _lastActiveTool;

  late final void Function(String) _toolbarActionHandler =
      _dispatchNativeToolbarAction;

  WindowService get nativeToolbarWindowService;

  AnnotationState? get nativeToolbarAnnotationState;

  bool get nativeToolbarShowPin;

  bool get nativeToolbarShowHistoryControls => true;

  bool get nativeToolbarAnchorToWindow => false;

  void handleNativeToolbarAction(String action);

  void initNativeToolbar() {
    nativeToolbarWindowService.onToolbarAction = _toolbarActionHandler;
  }

  void disposeNativeToolbar() {
    if (identical(
      nativeToolbarWindowService.onToolbarAction,
      _toolbarActionHandler,
    )) {
      nativeToolbarWindowService.onToolbarAction = null;
    }
    resetNativeToolbarSyncCache();
    unawaited(nativeToolbarWindowService.hideToolbarPanel());
  }

  void resetNativeToolbarSyncCache() {
    _lastToolbarRect = null;
    _lastShowPin = false;
    _lastShowHistoryControls = false;
    _lastCanUndo = false;
    _lastCanRedo = false;
    _lastActiveTool = null;
  }

  void hideNativeToolbar() {
    if (_lastToolbarRect == null &&
        !_lastShowPin &&
        !_lastShowHistoryControls &&
        !_lastCanUndo &&
        !_lastCanRedo &&
        _lastActiveTool == null) {
      return;
    }
    resetNativeToolbarSyncCache();
    unawaited(nativeToolbarWindowService.hideToolbarPanel());
  }

  void syncNativeToolbar(Rect toolbarRect) {
    final annotationState = nativeToolbarAnnotationState;
    final showHistoryControls = nativeToolbarShowHistoryControls;
    final canUndo = annotationState?.canUndo ?? false;
    final canRedo = annotationState?.canRedo ?? false;
    final activeTool = shapeTypeToToolId(activeShapeType);

    if (_lastToolbarRect == toolbarRect &&
        _lastShowPin == nativeToolbarShowPin &&
        _lastShowHistoryControls == showHistoryControls &&
        _lastCanUndo == canUndo &&
        _lastCanRedo == canRedo &&
        _lastActiveTool == activeTool) {
      return;
    }

    _lastToolbarRect = toolbarRect;
    _lastShowPin = nativeToolbarShowPin;
    _lastShowHistoryControls = showHistoryControls;
    _lastCanUndo = canUndo;
    _lastCanRedo = canRedo;
    _lastActiveTool = activeTool;

    unawaited(
      nativeToolbarWindowService.showToolbarPanel(
        rect: toolbarRect,
        showPin: nativeToolbarShowPin,
        showHistoryControls: showHistoryControls,
        canUndo: canUndo,
        canRedo: canRedo,
        activeTool: activeTool,
        anchorToWindow: nativeToolbarAnchorToWindow,
      ),
    );
  }

  void _dispatchNativeToolbarAction(String action) {
    final shapeType = toolIdToShapeType(action);
    if (shapeType != null) {
      handleToolTap(shapeType);
      return;
    }

    switch (action) {
      case 'undo':
        nativeToolbarAnnotationState?.undo();
        return;
      case 'redo':
        nativeToolbarAnnotationState?.redo();
        return;
      default:
        handleNativeToolbarAction(action);
        return;
    }
  }
}
