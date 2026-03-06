import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/window_service.dart';
import '../state/annotation_state.dart';
import '../utils/toolbar_layout.dart';
import '../widgets/annotation_overlay.dart';
import '../widgets/native_toolbar_mixin.dart';
import '../widgets/tool_popover_mixin.dart';

/// Fullscreen overlay that displays a scroll capture result.
///
/// The stitched image is shown in a centered, scrollable container with a
/// semi-transparent scrim behind it. Toolbar controls are rendered in a
/// separate native floating panel.
class ScrollResultScreen extends StatefulWidget {
  final ui.Image stitchedImage;
  final AnnotationState annotationState;
  final WindowService windowService;
  final VoidCallback onCopy;
  final VoidCallback onSave;
  final VoidCallback onDiscard;

  const ScrollResultScreen({
    super.key,
    required this.stitchedImage,
    required this.annotationState,
    required this.windowService,
    required this.onCopy,
    required this.onSave,
    required this.onDiscard,
  });

  @override
  State<ScrollResultScreen> createState() => _ScrollResultScreenState();
}

class _ScrollResultScreenState extends State<ScrollResultScreen>
    with ToolPopoverMixin, NativeToolbarMixin {
  final _focusNode = FocusNode();
  final _scrollController = ScrollController();

  final _popoverAnchorLink = LayerLink();

  @override
  AnnotationState get popoverAnnotationState => widget.annotationState;

  @override
  LayerLink get popoverAnchor => _popoverAnchorLink;

  @override
  WindowService get nativeToolbarWindowService => widget.windowService;

  @override
  AnnotationState get nativeToolbarAnnotationState => widget.annotationState;

  @override
  bool get nativeToolbarShowPin => false;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
    initNativeToolbar();
  }

  @override
  void dispose() {
    disposeNativeToolbar();
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    removePopover();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Keyboard
  // ---------------------------------------------------------------------------

  bool _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return false;

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
      if (widget.annotationState.editingText) return false;
      if (widget.annotationState.selectedIndex != null) {
        widget.annotationState.deleteSelected();
        return true;
      }
    }

    if (event.logicalKey == LogicalKeyboardKey.escape) {
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

  @override
  void handleNativeToolbarAction(String action) {
    switch (action) {
      case 'copy':
        widget.onCopy();
        return;
      case 'save':
        widget.onSave();
        return;
      case 'close':
        widget.onDiscard();
        return;
      default:
        return;
    }
  }

  // ---------------------------------------------------------------------------
  // Image container sizing
  // ---------------------------------------------------------------------------

  /// Compute the display rect for the image container, centered on screen.
  ///
  /// Width and height are computed independently because the container scrolls
  /// vertically — capping the height must NOT shrink the width.
  Rect _imageContainerRect(Size screenSize, {required Size toolbarSize}) {
    final image = widget.stitchedImage;

    final maxW = screenSize.width * 0.9;
    final availableHeight =
        (screenSize.height - toolbarSize.height - kToolbarGap * 2).clamp(
          1.0,
          screenSize.height,
        );
    final maxH = availableHeight < screenSize.height * 0.85
        ? availableHeight
        : screenSize.height * 0.85;

    // Width: match image pixel width, capped at maxW.
    // Do not force a larger minimum width: narrow captures should not be
    // stretched.
    final w = image.width.toDouble().clamp(1.0, maxW);

    // Height: the scaled image height at this width, capped at maxH.
    // The container scrolls, so height doesn't affect width.
    final scaledH = w * (image.height / image.width);
    final h = scaledH.clamp(1.0, maxH);

    final x = (screenSize.width - w) / 2;
    final y = ((availableHeight - h) / 2).clamp(0.0, availableHeight - h);
    return Rect.fromLTWH(x, y, w, h);
  }

  Rect _toolbarRect(
    Rect containerRect,
    Size screenSize, {
    required Size toolbarSize,
  }) {
    return computeFloatingToolbarRect(
      anchorRect: containerRect,
      screenSize: screenSize,
      toolbarSize: toolbarSize,
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      child: ListenableBuilder(
        listenable: widget.annotationState,
        builder: (context, _) {
          final screenSize = MediaQuery.sizeOf(context);
          final toolbarSize = computeNativeToolbarSize(
            showPin: false,
            showHistoryControls: true,
          );
          final containerRect = _imageContainerRect(
            screenSize,
            toolbarSize: toolbarSize,
          );
          final toolbarRect = _toolbarRect(
            containerRect,
            screenSize,
            toolbarSize: toolbarSize,
          );
          final image = widget.stitchedImage;
          final imagePixelSize = Size(
            image.width.toDouble(),
            image.height.toDouble(),
          );
          final scaledImageHeight =
              containerRect.width * (image.height / image.width);

          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            syncNativeToolbar(toolbarRect);
          });

          return Stack(
            children: [
              // Scrim background (full screen).
              const Positioned.fill(
                child: ColoredBox(color: Color(0x44000000)),
              ),

              // Click outside image → discard (when no tool is active).
              // Always present to keep the Stack child count stable — toggling
              // children shifts widget positions, causing the ScrollController
              // to momentarily attach to two scroll views during rebuilds.
              Positioned.fill(
                child: IgnorePointer(
                  ignoring: activeShapeType != null,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: widget.onDiscard,
                    child: const SizedBox.expand(),
                  ),
                ),
              ),

              // Image container with border.
              Positioned(
                left: containerRect.left,
                top: containerRect.top,
                width: containerRect.width,
                height: containerRect.height,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.3),
                      width: 1,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.5),
                        blurRadius: 24,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: ClipRect(
                    child: Stack(
                      children: [
                        // Scrollable image.
                        Positioned.fill(
                          child: SingleChildScrollView(
                            controller: _scrollController,
                            child: SizedBox(
                              width: containerRect.width,
                              height: scaledImageHeight,
                              child: RawImage(
                                image: image,
                                fit: BoxFit.fitWidth,
                              ),
                            ),
                          ),
                        ),

                        // Annotation overlay — outside the scroll view.
                        Positioned.fill(
                          child: IgnorePointer(
                            ignoring: activeShapeType == null,
                            child: ListenableBuilder(
                              listenable: Listenable.merge([
                                _scrollController,
                                widget.annotationState,
                              ]),
                              builder: (context, _) {
                                final scrollOffset =
                                    _scrollController.hasClients
                                    ? _scrollController.offset
                                    : 0.0;
                                final imageDisplayRect = Rect.fromLTWH(
                                  0,
                                  -scrollOffset,
                                  containerRect.width,
                                  scaledImageHeight,
                                );
                                final toolActive = activeShapeType != null;
                                return Listener(
                                  behavior: toolActive
                                      ? HitTestBehavior.opaque
                                      : HitTestBehavior.translucent,
                                  onPointerSignal: toolActive
                                      ? (event) {
                                          if (event is PointerScrollEvent &&
                                              _scrollController.hasClients) {
                                            final max = _scrollController
                                                .position
                                                .maxScrollExtent;
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
                                    enabled: toolActive,
                                    sourceImage: image,
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              // Toolbar — positioned below/above/inside the image container.
              Positioned(
                top: toolbarRect.top,
                left: toolbarRect.center.dx,
                child: CompositedTransformTarget(
                  link: _popoverAnchorLink,
                  child: const SizedBox(width: 1, height: 1),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
