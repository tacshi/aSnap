import 'dart:async';

import 'package:flutter/widgets.dart';

import '../services/window_service.dart';
import '../state/annotation_state.dart';
import '../utils/toolbar_actions.dart';
import 'tool_popover_mixin.dart';

/// Shared native toolbar lifecycle and action dispatch used by screens that
/// display the macOS native toolbar panel.
///
/// Mix this into a [State] that already uses [ToolPopoverMixin]. Implementors
/// must provide [nativeToolbarWindowService], [nativeToolbarAnnotationState],
/// and [nativeToolbarShowsPin]. Override [handleNativeAction] to dispatch
/// non-tool actions (copy, save, pin, discard) to screen-specific callbacks.
mixin NativeToolbarMixin<T extends StatefulWidget>
    on State<T>, ToolPopoverMixin<T> {
  // ---------------------------------------------------------------------------
  // State managed by the mixin
  // ---------------------------------------------------------------------------

  Rect? _lastNativeToolbarCgRect;
  bool nativeToolbarVisible = false;

  // ---------------------------------------------------------------------------
  // Abstract hooks — implementors must provide these
  // ---------------------------------------------------------------------------

  /// Whether the native toolbar is enabled for this screen.
  bool get useNativeToolbar;

  /// The window service to use for toolbar panel operations.
  WindowService get nativeToolbarWindowService;

  /// The annotation state to read undo/redo/hasAnnotations from.
  /// Return null if annotations are not available.
  AnnotationState? get nativeToolbarAnnotationState;

  /// Whether the Pin button should be shown in the toolbar.
  bool get nativeToolbarShowsPin;

  /// Called for non-tool actions (copy, save, pin, discard, undo, redo).
  /// The default implementation handles undo/redo via [nativeToolbarAnnotationState].
  /// Override to add handling for copy, save, pin, discard.
  void handleNativeAction(String action) {
    switch (action) {
      case 'undo':
        nativeToolbarAnnotationState?.undo();
        break;
      case 'redo':
        nativeToolbarAnnotationState?.redo();
        break;
    }
  }

  // ---------------------------------------------------------------------------
  // Lifecycle helpers — call from initState / dispose
  // ---------------------------------------------------------------------------

  /// Call from [initState] to register the toolbar action callback.
  void initNativeToolbar() {
    if (!useNativeToolbar) return;
    nativeToolbarWindowService.onToolbarAction = _handleNativeToolbarAction;
  }

  /// Call from [dispose] to unregister the toolbar action callback and hide
  /// the panel.
  ///
  /// The identity check ensures we only clear the callback if it still
  /// belongs to this instance. This is safe as long as only one screen
  /// using this mixin is active at a time (which the current architecture
  /// guarantees via state-driven routing).
  void disposeNativeToolbar() {
    if (nativeToolbarWindowService.onToolbarAction ==
        _handleNativeToolbarAction) {
      nativeToolbarWindowService.onToolbarAction = null;
    }
    if (useNativeToolbar) {
      unawaited(nativeToolbarWindowService.hideToolbarPanel());
    }
  }

  // ---------------------------------------------------------------------------
  // Toolbar state sync
  // ---------------------------------------------------------------------------

  /// Push the current tool/undo/redo state to the native toolbar panel.
  void syncNativeToolbarState() {
    final state = nativeToolbarAnnotationState;
    if (!useNativeToolbar || state == null) return;
    unawaited(
      nativeToolbarWindowService.updateToolbarState(
        activeTool: shapeTypeToToolId(activeShapeType),
        canUndo: state.canUndo,
        canRedo: state.canRedo,
        hasAnnotations: state.hasAnnotations,
        showsPin: nativeToolbarShowsPin,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Show / hide
  // ---------------------------------------------------------------------------

  /// Show the native toolbar at [cgRect] (CG coordinate space).
  /// If the toolbar is already visible at the same rect, only syncs state.
  void showNativeToolbarAtCgRect(Rect cgRect) {
    if (nativeToolbarVisible && _lastNativeToolbarCgRect == cgRect) {
      syncNativeToolbarState();
      return;
    }
    nativeToolbarVisible = true;
    _lastNativeToolbarCgRect = cgRect;
    unawaited(
      nativeToolbarWindowService.showToolbarPanel(
        centerX: cgRect.center.dx,
        belowY: cgRect.top,
      ),
    );
    syncNativeToolbarState();
  }

  /// Show the native toolbar below [localRect], shifted by [screenOrigin]
  /// to convert from local to CG coordinates.
  void showNativeToolbarBelow(Rect localRect, Offset screenOrigin) {
    showNativeToolbarAtCgRect(localRect.shift(screenOrigin));
  }

  /// Hide the native toolbar panel.
  void hideNativeToolbar() {
    if (!nativeToolbarVisible) return;
    nativeToolbarVisible = false;
    _lastNativeToolbarCgRect = null;
    unawaited(nativeToolbarWindowService.hideToolbarPanel());
  }

  // ---------------------------------------------------------------------------
  // Action routing
  // ---------------------------------------------------------------------------

  void _handleNativeToolbarAction(String action) {
    if (action.startsWith('toolTap:')) {
      final toolId = action.substring('toolTap:'.length);
      final type = toolIdToShapeType(toolId);
      if (type != null) handleToolTap(type);
      return;
    }
    handleNativeAction(action);
  }
}
