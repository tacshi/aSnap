import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../state/annotation_state.dart';
import '../state/app_state.dart';
import '../utils/toolbar_layout.dart';
import '../widgets/annotation_overlay.dart';
import '../widgets/selection_toolbar.dart';
import '../widgets/tool_popover_mixin.dart';

/// Floating preview window for normal (non-scroll) captures.
///
/// Scroll capture results are handled by [ScrollResultScreen] in a fullscreen
/// overlay instead.
class PreviewScreen extends StatefulWidget {
  final AppState appState;
  final AnnotationState annotationState;
  final VoidCallback onCopy;
  final VoidCallback onSave;
  final VoidCallback? onPin;
  final VoidCallback onDiscard;

  const PreviewScreen({
    super.key,
    required this.appState,
    required this.annotationState,
    required this.onCopy,
    required this.onSave,
    this.onPin,
    required this.onDiscard,
  });

  @override
  State<PreviewScreen> createState() => _PreviewScreenState();
}

class _PreviewScreenState extends State<PreviewScreen> with ToolPopoverMixin {
  final _focusNode = FocusNode();
  bool _focusRetryRunning = false;

  final _popoverAnchorLink = LayerLink();

  /// Tracks the last image to detect capture changes and reset annotation UI.
  ui.Image? _lastImage;

  @override
  AnnotationState get popoverAnnotationState => widget.annotationState;

  @override
  LayerLink get popoverAnchor => _popoverAnchorLink;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    removePopover();
    _focusNode.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Focus management
  // ---------------------------------------------------------------------------

  void _scheduleFocusSync() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _focusNode.hasFocus || _focusRetryRunning) return;
      _focusRetryRunning = true;
      _requestFocusWithRetry().whenComplete(() {
        _focusRetryRunning = false;
      });
    });
  }

  Future<void> _requestFocusWithRetry() async {
    for (var attempt = 0; attempt < 20; attempt++) {
      if (!mounted || _focusNode.hasFocus) return;
      await windowManager.focus();
      _focusNode.requestFocus();
      if (_focusNode.hasFocus) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  // ---------------------------------------------------------------------------
  // Keyboard (HardwareKeyboard — focus-independent)
  // ---------------------------------------------------------------------------

  bool _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    // Only handle keys when preview is active with an image.
    if (widget.appState.capturedImage == null) return false;

    final meta =
        HardwareKeyboard.instance.logicalKeysPressed.contains(
          LogicalKeyboardKey.metaLeft,
        ) ||
        HardwareKeyboard.instance.logicalKeysPressed.contains(
          LogicalKeyboardKey.metaRight,
        );
    final shift =
        HardwareKeyboard.instance.logicalKeysPressed.contains(
          LogicalKeyboardKey.shiftLeft,
        ) ||
        HardwareKeyboard.instance.logicalKeysPressed.contains(
          LogicalKeyboardKey.shiftRight,
        );

    // Cmd+Shift+Z → redo
    if (meta && shift && event.logicalKey == LogicalKeyboardKey.keyZ) {
      widget.annotationState.redo();
      return true;
    }
    // Cmd+Z → undo
    if (meta && event.logicalKey == LogicalKeyboardKey.keyZ) {
      widget.annotationState.undo();
      return true;
    }
    // Cmd+Shift+P → pin to screen
    if (meta && shift && event.logicalKey == LogicalKeyboardKey.keyP) {
      widget.onPin?.call();
      return true;
    }

    // Delete/Backspace → delete selected annotation.
    if (event.logicalKey == LogicalKeyboardKey.delete ||
        event.logicalKey == LogicalKeyboardKey.backspace) {
      // Don't delete annotation while editing text (Backspace is used in TextField).
      if (widget.annotationState.editingText) return false;
      if (widget.annotationState.selectedIndex != null) {
        widget.annotationState.deleteSelected();
        return true;
      }
    }

    if (event.logicalKey == LogicalKeyboardKey.escape) {
      // Cancel text editing first.
      if (widget.annotationState.editingText) {
        widget.annotationState.cancelTextEdit();
        return true;
      }
      if (popoverVisible) {
        removePopover();
        return true;
      }
      if (activeShapeType != null) {
        setState(() => activeShapeType = null);
        return true;
      }
      widget.onDiscard();
      return true;
    }
    return false;
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.appState, widget.annotationState]),
      builder: (context, _) {
        final image = widget.appState.capturedImage;
        if (image == null) {
          _lastImage = null;
          return const ColoredBox(color: Color(0xFF1E1E1E));
        }

        // Reset annotation UI when the image changes (new capture).
        if (_lastImage != null && !identical(image, _lastImage)) {
          removePopover();
          activeShapeType = null;
        }
        _lastImage = image;

        _scheduleFocusSync();
        return Focus(
          focusNode: _focusNode,
          autofocus: true,
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Compute the actual rect where the image renders with BoxFit.contain.
              final imageSize = Size(
                image.width.toDouble(),
                image.height.toDouble(),
              );
              final fitted = applyBoxFit(
                BoxFit.contain,
                imageSize,
                constraints.biggest,
              );
              final imageDisplayRect = Alignment.center.inscribe(
                fitted.destination,
                Offset.zero & constraints.biggest,
              );
              final toolbarRect = computeToolbarRect(
                anchorRect: imageDisplayRect,
                screenSize: constraints.biggest,
              );

              return Stack(
                fit: StackFit.expand,
                children: [
                  // Screenshot image.
                  RawImage(image: image, fit: BoxFit.contain),

                  // Annotation overlay.
                  AnnotationOverlay(
                    annotationState: widget.annotationState,
                    imageDisplayRect: imageDisplayRect,
                    imagePixelSize: imageSize,
                    enabled: activeShapeType != null,
                    sourceImage: image,
                  ),

                  // Window drag area (only when NOT drawing). Keep this below
                  // the in-window toolbar so action buttons remain clickable.
                  if (activeShapeType == null)
                    Positioned.fill(
                      child: DragToMoveArea(child: const SizedBox.expand()),
                    ),

                  Positioned(
                    left: toolbarRect.left,
                    top: toolbarRect.top,
                    child: MouseRegion(
                      cursor: SystemMouseCursors.basic,
                      child: SelectionToolbar(
                        onCopy: widget.onCopy,
                        onSave: widget.onSave,
                        onPin: widget.onPin,
                        onClose: widget.onDiscard,
                        onToolTap: handleToolTap,
                        onUndo: widget.annotationState.undo,
                        onRedo: widget.annotationState.redo,
                        activeShapeType: activeShapeType,
                        hasAnnotations: widget.annotationState.hasAnnotations,
                        canUndo: widget.annotationState.canUndo,
                        canRedo: widget.annotationState.canRedo,
                        settingsLayerLink: _popoverAnchorLink,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}
