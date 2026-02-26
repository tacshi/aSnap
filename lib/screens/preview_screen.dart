import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../state/annotation_state.dart';
import '../state/app_state.dart';
import '../services/window_service.dart';
import '../utils/toolbar_layout.dart';
import '../widgets/annotation_overlay.dart';
import '../widgets/native_toolbar_mixin.dart';
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
  final WindowService windowService;
  final bool useNativeToolbar;

  const PreviewScreen({
    super.key,
    required this.appState,
    required this.annotationState,
    required this.onCopy,
    required this.onSave,
    this.onPin,
    required this.onDiscard,
    required this.windowService,
    required this.useNativeToolbar,
  });

  @override
  State<PreviewScreen> createState() => _PreviewScreenState();
}

class _PreviewScreenState extends State<PreviewScreen>
    with ToolPopoverMixin, NativeToolbarMixin, WindowListener {
  final _focusNode = FocusNode();
  bool _focusRetryRunning = false;

  final _popoverAnchorLink = LayerLink();

  /// Tracks the last image to detect capture changes and reset annotation UI.
  ui.Image? _lastImage;

  // -- Native toolbar anchor for popover positioning --
  Offset? _toolbarAnchorOffset;

  @override
  AnnotationState get popoverAnnotationState => widget.annotationState;

  @override
  LayerLink get popoverAnchor => _popoverAnchorLink;

  @override
  bool get useNativeToolbar => widget.useNativeToolbar;

  @override
  WindowService get nativeToolbarWindowService => widget.windowService;

  @override
  AnnotationState get nativeToolbarAnnotationState => widget.annotationState;

  @override
  bool get nativeToolbarShowsPin => widget.onPin != null;

  @override
  void handleNativeAction(String action) {
    switch (action) {
      case 'undo':
        widget.annotationState.undo();
        break;
      case 'redo':
        widget.annotationState.redo();
        break;
      case 'copy':
        widget.onCopy();
        break;
      case 'save':
        widget.onSave();
        break;
      case 'pin':
        widget.onPin?.call();
        break;
      case 'discard':
        widget.onDiscard();
        break;
    }
  }

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
    initNativeToolbar();
    if (widget.useNativeToolbar) {
      widget.windowService.onToolbarNeedsUpdate = _handleToolbarNeedsUpdate;
      windowManager.addListener(this);
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    disposeNativeToolbar();
    if (widget.windowService.onToolbarNeedsUpdate ==
        _handleToolbarNeedsUpdate) {
      widget.windowService.onToolbarNeedsUpdate = null;
    }
    if (widget.useNativeToolbar) {
      windowManager.removeListener(this);
    }
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
  // Native toolbar placement (PreviewScreen-specific: below floating window)
  // ---------------------------------------------------------------------------

  Future<void> _updateNativeToolbarPlacement() async {
    if (!widget.useNativeToolbar) return;
    if (!widget.windowService.toolbarUpdatesEnabled) return;
    if (widget.appState.capturedImage == null) {
      hideNativeToolbar();
      return;
    }
    final windowPos = await windowManager.getPosition();
    final windowSize = await windowManager.getSize();
    final windowRect = Rect.fromLTWH(
      windowPos.dx,
      windowPos.dy,
      windowSize.width,
      windowSize.height,
    );
    final screenInfo =
        await widget.windowService.getScreenInfoForRect(windowRect) ??
        await widget.windowService.getScreenInfo();
    if (screenInfo == null) return;

    final screenRect = Rect.fromLTWH(
      screenInfo.screenOrigin.dx,
      screenInfo.screenOrigin.dy,
      screenInfo.screenSize.width,
      screenInfo.screenSize.height,
    );

    final cgRect = computeToolbarRectBelowWindow(
      windowRect: windowRect,
      screenRect: screenRect,
    );

    final anchorX = (cgRect.center.dx - windowPos.dx).clamp(
      0.0,
      windowSize.width - 1,
    );
    final anchorY = (windowSize.height - 1).clamp(0.0, windowSize.height);
    final newAnchor = Offset(anchorX, anchorY);
    if (_toolbarAnchorOffset != newAnchor) {
      _toolbarAnchorOffset = newAnchor;
      if (mounted) {
        setState(() {});
      }
    }

    showNativeToolbarAtCgRect(cgRect);
  }

  void _handleToolbarNeedsUpdate() {
    unawaited(_updateNativeToolbarPlacement());
  }

  @override
  void onWindowMove() {
    unawaited(_updateNativeToolbarPlacement());
  }

  @override
  void onWindowResize() {
    unawaited(_updateNativeToolbarPlacement());
  }

  @override
  void onWindowMoved() {
    unawaited(_updateNativeToolbarPlacement());
  }

  @override
  void onWindowResized() {
    unawaited(_updateNativeToolbarPlacement());
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
          if (widget.useNativeToolbar) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) hideNativeToolbar();
            });
          }
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
              final fallbackToolbarRect = computeToolbarRect(
                anchorRect: imageDisplayRect,
                screenSize: constraints.biggest,
              );
              if (widget.useNativeToolbar) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) unawaited(_updateNativeToolbarPlacement());
                });
                syncNativeToolbarState();
              }

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

                  if (widget.useNativeToolbar)
                    Positioned(
                      left:
                          _toolbarAnchorOffset?.dx ??
                          (constraints.biggest.width / 2),
                      top:
                          _toolbarAnchorOffset?.dy ??
                          (constraints.biggest.height - 1),
                      width: 1,
                      height: 1,
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: CompositedTransformTarget(
                          link: _popoverAnchorLink,
                          child: const SizedBox(width: 1, height: 1),
                        ),
                      ),
                    )
                  else
                    Positioned(
                      left: fallbackToolbarRect.left,
                      top: fallbackToolbarRect.top,
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
