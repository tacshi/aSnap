import 'package:flutter/material.dart';

import '../models/annotation.dart';
import '../state/annotation_state.dart';
import 'shape_popover.dart';

/// Shared popover and tool-selection logic used by both [PreviewScreen] and
/// [RegionSelectionScreen].
///
/// Mix this into a [State] subclass and provide [popoverAnnotationState] and
/// [popoverAnchor] so the mixin can build overlay entries and update settings.
mixin ToolPopoverMixin<T extends StatefulWidget> on State<T> {
  // ---------------------------------------------------------------------------
  // State managed by the mixin
  // ---------------------------------------------------------------------------

  ShapeType? activeShapeType;
  bool popoverVisible = false;
  OverlayEntry? _popoverEntry;

  // ---------------------------------------------------------------------------
  // Abstract hooks — implementors must provide these
  // ---------------------------------------------------------------------------

  /// The annotation state to update when a tool is selected.
  /// Return null if annotations are not available in the current context.
  AnnotationState? get popoverAnnotationState;

  /// The [LayerLink] that anchors the popover to the toolbar's settings button.
  LayerLink get popoverAnchor;

  // ---------------------------------------------------------------------------
  // Popover lifecycle
  // ---------------------------------------------------------------------------

  /// Handles tapping a tool button in the toolbar.
  ///
  /// - First tap on an inactive tool: activates it and shows settings popover.
  /// - Tap on the already active tool: toggles the settings popover.
  /// - Tap on a different tool while one is active: switches tool, shows popover.
  void handleToolTap(ShapeType type) {
    setState(() {
      if (activeShapeType == type) {
        // Same tool tapped — toggle popover visibility.
        if (popoverVisible) {
          removePopover();
        } else {
          showPopover();
        }
      } else {
        // Different tool (or no tool active) — activate and show popover.
        activeShapeType = type;
        final state = popoverAnnotationState;
        if (state != null) {
          state.updateSettings(state.settings.copyWith(shapeType: type));
        }
        showPopover();
      }
    });
  }

  /// Shows the settings popover anchored to [popoverAnchor].
  ///
  /// Removes any existing popover first, then inserts a new [OverlayEntry].
  void showPopover() {
    removePopover();
    final state = popoverAnnotationState;
    if (state == null) return;
    popoverVisible = true;
    _popoverEntry = OverlayEntry(
      builder: (_) => CompositedTransformFollower(
        link: popoverAnchor,
        targetAnchor: Alignment.topCenter,
        followerAnchor: Alignment.bottomCenter,
        offset: const Offset(0, -8),
        child: Align(
          alignment: Alignment.bottomCenter,
          child: ShapePopover(
            annotationState: state,
            onDismiss: () {
              removePopover();
              popoverVisible = false;
            },
          ),
        ),
      ),
    );
    Overlay.of(context).insert(_popoverEntry!);
  }

  /// Removes the popover overlay entry and resets visibility state.
  void removePopover() {
    _popoverEntry?.remove();
    _popoverEntry = null;
    popoverVisible = false;
  }
}
