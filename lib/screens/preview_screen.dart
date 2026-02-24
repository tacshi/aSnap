import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../state/annotation_state.dart';
import '../state/app_state.dart';
import '../widgets/annotation_overlay.dart';
import '../widgets/preview_toolbar.dart';
import '../widgets/shape_popover.dart';

class PreviewScreen extends StatefulWidget {
  final AppState appState;
  final AnnotationState annotationState;
  final VoidCallback onCopy;
  final VoidCallback onSave;
  final VoidCallback onDiscard;

  const PreviewScreen({
    super.key,
    required this.appState,
    required this.annotationState,
    required this.onCopy,
    required this.onSave,
    required this.onDiscard,
  });

  @override
  State<PreviewScreen> createState() => _PreviewScreenState();
}

class _PreviewScreenState extends State<PreviewScreen> {
  final _focusNode = FocusNode();
  final _scrollController = ScrollController();
  bool _focusRetryRunning = false;

  bool _shapesActive = false;
  bool _popoverVisible = false;
  final _shapesLayerLink = LayerLink();
  OverlayEntry? _popoverEntry;

  /// Tracks the last image to detect capture changes and reset annotation UI.
  ui.Image? _lastImage;

  @override
  void initState() {
    super.initState();
    // Use HardwareKeyboard for focus-independent key handling.
    // This avoids issues where SingleChildScrollView's Scrollable steals
    // focus from KeyboardListener, breaking Escape and shortcuts.
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    _removePopover();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

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
  // Shapes popover
  // ---------------------------------------------------------------------------

  void _toggleShapes() {
    setState(() {
      if (!_shapesActive) {
        _shapesActive = true;
        _showPopover();
      } else if (_popoverVisible) {
        _removePopover();
        _shapesActive = false;
      } else {
        // Mode active but popover dismissed → re-show settings.
        _showPopover();
      }
    });
  }

  void _showPopover() {
    _removePopover();
    _popoverVisible = true;
    _popoverEntry = OverlayEntry(
      builder: (_) => Stack(
        children: [
          ShapePopover(
            annotationState: widget.annotationState,
            layerLink: _shapesLayerLink,
            onDismiss: () {
              _removePopover();
              _popoverVisible = false;
            },
          ),
        ],
      ),
    );
    Overlay.of(context).insert(_popoverEntry!);
  }

  void _removePopover() {
    _popoverEntry?.remove();
    _popoverEntry = null;
    _popoverVisible = false;
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

    // Delete/Backspace → delete selected annotation.
    if (event.logicalKey == LogicalKeyboardKey.delete ||
        event.logicalKey == LogicalKeyboardKey.backspace) {
      if (widget.annotationState.selectedIndex != null) {
        widget.annotationState.deleteSelected();
        return true;
      }
    }

    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (_popoverVisible) {
        _removePopover();
        return true;
      }
      if (_shapesActive) {
        setState(() => _shapesActive = false);
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
          _removePopover();
          _shapesActive = false;
        }
        _lastImage = image;

        _scheduleFocusSync();
        return Focus(
          focusNode: _focusNode,
          autofocus: true,
          child: widget.appState.isScrollCapture
              ? _buildScrollPreview(image)
              : _buildNormalPreview(image),
        );
      },
    );
  }

  Widget _buildNormalPreview(ui.Image image) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Compute the actual rect where the image renders with BoxFit.contain.
        final imageSize = Size(image.width.toDouble(), image.height.toDouble());
        final fitted = applyBoxFit(
          BoxFit.contain,
          imageSize,
          constraints.biggest,
        );
        final imageDisplayRect = Alignment.center.inscribe(
          fitted.destination,
          Offset.zero & constraints.biggest,
        );

        return Stack(
          fit: StackFit.expand,
          children: [
            // Window drag area (only when NOT drawing).
            if (!_shapesActive) DragToMoveArea(child: const SizedBox.expand()),

            // Screenshot image.
            RawImage(image: image, fit: BoxFit.contain),

            // Annotation overlay.
            AnnotationOverlay(
              annotationState: widget.annotationState,
              imageDisplayRect: imageDisplayRect,
              imagePixelSize: imageSize,
              enabled: _shapesActive,
            ),

            // Toolbar.
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Center(
                child: PreviewToolbar(
                  onCopy: widget.onCopy,
                  onSave: widget.onSave,
                  onDiscard: widget.onDiscard,
                  onShapesToggle: _toggleShapes,
                  shapesActive: _shapesActive,
                  hasAnnotations: widget.annotationState.hasAnnotations,
                  canUndo: widget.annotationState.canUndo,
                  canRedo: widget.annotationState.canRedo,
                  onUndo: widget.annotationState.undo,
                  onRedo: widget.annotationState.redo,
                  shapesLayerLink: _shapesLayerLink,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildScrollPreview(ui.Image image) {
    // Scrollable layout for tall stitched images — no DragToMoveArea
    // (conflicts with scroll gesture).
    //
    // The annotation overlay sits OUTSIDE the scroll view so it can block
    // drag gestures (for drawing) while still allowing trackpad scroll.
    // It adjusts imageDisplayRect by the scroll offset so annotations
    // stay anchored to image pixels.
    final imagePixelSize = Size(
      image.width.toDouble(),
      image.height.toDouble(),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final imageHeight = constraints.maxWidth * (image.height / image.width);

        return Stack(
          children: [
            // Scrollable image.
            Positioned.fill(
              child: SingleChildScrollView(
                controller: _scrollController,
                child: SizedBox(
                  width: constraints.maxWidth,
                  height: imageHeight,
                  child: RawImage(image: image, fit: BoxFit.fitWidth),
                ),
              ),
            ),

            // Annotation overlay — outside the scroll view.
            // When shapes active: opaque blocks drag-to-scroll, forwards
            // trackpad scroll to controller. When inactive: IgnorePointer
            // lets all events through to the scroll view while still
            // rendering committed annotations.
            Positioned.fill(
              child: IgnorePointer(
                ignoring: !_shapesActive,
                child: ListenableBuilder(
                  listenable: Listenable.merge([
                    _scrollController,
                    widget.annotationState,
                  ]),
                  builder: (context, _) {
                    final scrollOffset = _scrollController.hasClients
                        ? _scrollController.offset
                        : 0.0;
                    final imageDisplayRect = Rect.fromLTWH(
                      0,
                      -scrollOffset,
                      constraints.maxWidth,
                      imageHeight,
                    );
                    return Listener(
                      behavior: _shapesActive
                          ? HitTestBehavior.opaque
                          : HitTestBehavior.translucent,
                      onPointerSignal: _shapesActive
                          ? (event) {
                              // Forward trackpad scroll to the scroll view.
                              if (event is PointerScrollEvent &&
                                  _scrollController.hasClients) {
                                final max =
                                    _scrollController.position.maxScrollExtent;
                                _scrollController.jumpTo(
                                  (_scrollController.offset +
                                          event.scrollDelta.dy)
                                      .clamp(0.0, max),
                                );
                              }
                            }
                          : null,
                      child: AnnotationOverlay(
                        annotationState: widget.annotationState,
                        imageDisplayRect: imageDisplayRect,
                        imagePixelSize: imagePixelSize,
                        enabled: _shapesActive,
                      ),
                    );
                  },
                ),
              ),
            ),

            // Toolbar.
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.black54],
                  ),
                ),
                child: Center(
                  child: PreviewToolbar(
                    onCopy: widget.onCopy,
                    onSave: widget.onSave,
                    onDiscard: widget.onDiscard,
                    onShapesToggle: _toggleShapes,
                    shapesActive: _shapesActive,
                    hasAnnotations: widget.annotationState.hasAnnotations,
                    canUndo: widget.annotationState.canUndo,
                    canRedo: widget.annotationState.canRedo,
                    onUndo: widget.annotationState.undo,
                    onRedo: widget.annotationState.redo,
                    shapesLayerLink: _shapesLayerLink,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
