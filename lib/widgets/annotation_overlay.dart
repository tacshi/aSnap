import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/annotation.dart';
import '../models/annotation_handle.dart';
import '../models/annotation_hit_test.dart';
import '../state/annotation_state.dart';
import 'annotation_painter.dart';

/// Interactive overlay for drawing annotation shapes on a screenshot.
///
/// Placed in a [Stack] above the screenshot image, below the toolbar.
/// Translates pointer events from widget coordinates to image pixel
/// coordinates using [imageDisplayRect] and [imagePixelSize].
///
/// When [handlePointerEvents] is `false`, the overlay only paints
/// annotations and shows the cursor — pointer events are handled
/// externally (e.g. by the parent widget).
class AnnotationOverlay extends StatefulWidget {
  final AnnotationState annotationState;

  /// The rect (in widget coordinates) where the image is actually rendered.
  /// Used to map pointer positions to image pixel space.
  final Rect imageDisplayRect;

  /// The image dimensions in physical pixels.
  final Size imagePixelSize;

  /// Whether drawing is active (shapes tool selected).
  final bool enabled;

  /// Whether this overlay should handle pointer events itself.
  ///
  /// Set to `false` when the parent manages pointer routing (e.g. to
  /// allow handle drags to take priority over annotation drawing).
  final bool handlePointerEvents;

  /// Original screenshot image, needed for mosaic/blur rendering.
  final ui.Image? sourceImage;
  final Offset sourceImageOffset;

  const AnnotationOverlay({
    super.key,
    required this.annotationState,
    required this.imageDisplayRect,
    required this.imagePixelSize,
    required this.enabled,
    this.handlePointerEvents = true,
    this.sourceImage,
    this.sourceImageOffset = Offset.zero,
  });

  @override
  State<AnnotationOverlay> createState() => _AnnotationOverlayState();
}

class _AnnotationOverlayState extends State<AnnotationOverlay> {
  // Handle drag state.
  bool _draggingHandle = false;
  AnnHandle? _activeHandle;

  // Text move drag state.
  bool _movingAnnotation = false;
  Offset? _moveStartImagePoint;

  // Double-click detection.
  DateTime? _lastPointerDown;
  Offset? _lastPointerDownPos;

  // Text editing.
  final TextEditingController _textController = TextEditingController();
  final FocusNode _textFocusNode = FocusNode();
  bool _wasEditingText = false;

  // Pre-loaded raw RGBA pixel data for mosaic pixelation.
  ByteData? _sourcePixels;
  ui.Image? _pixelsForImage;

  @override
  void initState() {
    super.initState();
    widget.annotationState.addListener(_onAnnotationStateChanged);
    _updateSourcePixels();
  }

  @override
  void didUpdateWidget(AnnotationOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.annotationState != widget.annotationState) {
      oldWidget.annotationState.removeListener(_onAnnotationStateChanged);
      widget.annotationState.addListener(_onAnnotationStateChanged);
    }
    if (!identical(widget.sourceImage, oldWidget.sourceImage)) {
      _updateSourcePixels();
    }
  }

  /// Async-load raw RGBA pixels from [widget.sourceImage] for mosaic
  /// pixelation. The painter can't call async methods, so we pre-load here.
  void _updateSourcePixels() {
    final image = widget.sourceImage;
    if (image == null) {
      _sourcePixels = null;
      _pixelsForImage = null;
      return;
    }
    if (identical(image, _pixelsForImage)) return;
    // Keep a reference so we don't reload for the same image.
    _pixelsForImage = image;
    image.toByteData(format: ui.ImageByteFormat.rawRgba).then((bytes) {
      if (!mounted) return;
      if (!identical(widget.sourceImage, image)) return; // stale
      setState(() => _sourcePixels = bytes);
    });
  }

  @override
  void dispose() {
    widget.annotationState.removeListener(_onAnnotationStateChanged);
    _textController.dispose();
    _textFocusNode.dispose();
    super.dispose();
  }

  /// Clears the text controller and requests focus when text editing starts.
  ///
  /// This handles both modes: when [handlePointerEvents] is `true` (overlay
  /// manages events) and `false` (parent calls [AnnotationState.startTextEdit]
  /// directly without access to the overlay's private controller).
  void _onAnnotationStateChanged() {
    final editing = widget.annotationState.editingText;
    if (editing && !_wasEditingText) {
      _textController.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _textFocusNode.requestFocus();
      });
    }
    _wasEditingText = editing;
  }

  Offset _widgetToImage(Offset widgetPoint) {
    final scaleX = widget.imagePixelSize.width / widget.imageDisplayRect.width;
    final scaleY =
        widget.imagePixelSize.height / widget.imageDisplayRect.height;
    return Offset(
      (widgetPoint.dx - widget.imageDisplayRect.left) * scaleX,
      (widgetPoint.dy - widget.imageDisplayRect.top) * scaleY,
    );
  }

  Offset _imageToWidget(Offset imagePoint) {
    final scaleX = widget.imageDisplayRect.width / widget.imagePixelSize.width;
    final scaleY =
        widget.imageDisplayRect.height / widget.imagePixelSize.height;
    return Offset(
      widget.imageDisplayRect.left + imagePoint.dx * scaleX,
      widget.imageDisplayRect.top + imagePoint.dy * scaleY,
    );
  }

  bool _isShiftHeld() {
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    return keys.contains(LogicalKeyboardKey.shiftLeft) ||
        keys.contains(LogicalKeyboardKey.shiftRight);
  }

  void _onPointerDown(PointerDownEvent event) {
    if (!widget.enabled) return;
    // Only handle primary button.
    if (event.buttons != kPrimaryButton) return;

    // Commit any in-progress text edit on click-away. Don't start a new
    // action on the same click — the user must click again.
    if (widget.annotationState.editingText) {
      _commitTextEdit();
      return;
    }

    // Ignore clicks outside the image area.
    if (!widget.imageDisplayRect.contains(event.localPosition)) return;

    final imagePoint = _widgetToImage(event.localPosition);
    final state = widget.annotationState;

    // 1. ALWAYS record timing for double-click detection.
    final now = DateTime.now();
    final isDoubleClick =
        _lastPointerDown != null &&
        _lastPointerDownPos != null &&
        now.difference(_lastPointerDown!) < const Duration(milliseconds: 400) &&
        (imagePoint - _lastPointerDownPos!).distance < 10;
    _lastPointerDown = now;
    _lastPointerDownPos = imagePoint;

    // 2. Check double-click BEFORE handle hit (so adding 2nd CP works).
    if (isDoubleClick) {
      _handleDoubleClick(imagePoint);
      _lastPointerDown = null; // reset after consuming
      _lastPointerDownPos = null;
      return;
    }

    // 3. Check handle hit on selected shape.
    if (state.selectedAnnotation != null) {
      final handles = annotationHandles(state.selectedAnnotation!);
      final hit = hitTestAnnotationHandle(imagePoint, handles);
      if (hit != null) {
        _draggingHandle = true;
        _activeHandle = hit;
        state.beginEdit();
        return;
      }

      // 3b. Text/stamp body hit on selected annotation → start move drag.
      if (state.selectedAnnotation!.isText ||
          state.selectedAnnotation!.isStamp) {
        if (state.selectedAnnotation!.boundingRect.contains(imagePoint)) {
          _movingAnnotation = true;
          _moveStartImagePoint = imagePoint;
          state.beginEdit();
          return;
        }
      }
    }

    // 4. Check shape stroke hit → select.
    final hitIdx = hitTestAnnotations(imagePoint, state.annotations);
    if (hitIdx != null) {
      state.selectAnnotation(hitIdx);
      return;
    }

    // 5. Empty space → deselect. Stamp/text tools commit immediately; others drag.
    state.deselectAnnotation();
    if (state.settings.shapeType == ShapeType.number) {
      state.placeStamp(imagePoint);
      return;
    }
    if (state.settings.shapeType == ShapeType.text) {
      _beginTextEdit(imagePoint);
      return;
    }
    state.startDrawing(imagePoint);
  }

  void _onPointerMove(PointerMoveEvent event) {
    // Move drag for text annotations.
    if (_movingAnnotation && _moveStartImagePoint != null) {
      final imagePoint = _widgetToImage(event.localPosition);
      final delta = imagePoint - _moveStartImagePoint!;
      _moveStartImagePoint = imagePoint;
      final selected = widget.annotationState.selectedAnnotation;
      if (selected != null) {
        widget.annotationState.updateSelected(selected.translated(delta));
      }
      return;
    }

    if (_draggingHandle && _activeHandle != null) {
      final imagePoint = _widgetToImage(event.localPosition);
      final state = widget.annotationState;
      if (state.selectedAnnotation != null) {
        final updated = applyAnnotationHandleDrag(
          state.selectedAnnotation!,
          _activeHandle!,
          imagePoint,
        );
        // Update handle position for next drag.
        _activeHandle = AnnHandle(
          _activeHandle!.type,
          imagePoint,
          controlPointIndex: _activeHandle!.controlPointIndex,
        );
        state.updateSelected(updated);
      }
      return;
    }
    if (widget.annotationState.activeAnnotation == null) return;
    final imagePoint = _widgetToImage(event.localPosition);
    widget.annotationState.updateDrawing(
      imagePoint,
      constrained: _isShiftHeld(),
    );
  }

  void _onPointerUp(PointerUpEvent event) {
    if (_movingAnnotation) {
      _movingAnnotation = false;
      _moveStartImagePoint = null;
      widget.annotationState.commitEdit();
      return;
    }
    if (_draggingHandle) {
      _draggingHandle = false;
      _activeHandle = null;
      widget.annotationState.commitEdit();
      return;
    }
    if (widget.annotationState.activeAnnotation == null) return;
    widget.annotationState.finishDrawing();
  }

  void _beginTextEdit(Offset imagePoint) {
    // Controller clearing and focus request are handled by
    // _onAnnotationStateChanged when editingText transitions to true.
    widget.annotationState.startTextEdit(imagePoint);
  }

  void _commitTextEdit() {
    final state = widget.annotationState;
    if (!state.editingText || state.textEditPosition == null) return;

    final content = _textController.text;
    if (content.trim().isEmpty) {
      state.cancelTextEdit();
      return;
    }

    // Compute the bounding box end from the text layout.
    final baseFontSize = state.settings.strokeWidth * 4;
    final textPainter = TextPainter(
      text: TextSpan(
        text: content,
        style: TextStyle(
          fontSize: baseFontSize,
          fontFamily: state.settings.fontFamily,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final start = state.textEditPosition!;
    final boundingEnd = Offset(
      start.dx + textPainter.width,
      start.dy + textPainter.height,
    );
    state.commitText(content, boundingEnd);
  }

  void _cancelTextEdit() {
    widget.annotationState.cancelTextEdit();
  }

  void _handleDoubleClick(Offset imagePoint) {
    final state = widget.annotationState;

    // Cancel any accidental drawing from the first click's empty-space path.
    if (state.activeAnnotation != null) {
      state.cancelDrawing();
    }

    // Use selected annotation if it's a valid target.
    if (state.selectedAnnotation != null) {
      final a = state.selectedAnnotation!;
      if ((a.type == ShapeType.line || a.type == ShapeType.arrow) &&
          a.controlPoints.length < 2) {
        state.beginEdit();
        state.updateSelected(a.addControlPoint(imagePoint));
        state.commitEdit();
        return;
      }
    }

    // Fallback: find a nearby line/arrow to add CP to (generous threshold).
    final hitIdx = hitTestAnnotations(
      imagePoint,
      state.annotations,
      threshold: 20,
    );
    if (hitIdx == null) return;
    final target = state.annotations[hitIdx];
    if (target.type != ShapeType.line && target.type != ShapeType.arrow) return;
    if (target.controlPoints.length >= 2) return;

    state.selectAnnotation(hitIdx);
    state.beginEdit();
    state.updateSelected(target.addControlPoint(imagePoint));
    state.commitEdit();
  }

  Widget _buildTextEditOverlay() {
    final state = widget.annotationState;
    if (!state.editingText || state.textEditPosition == null) {
      return const SizedBox.shrink();
    }

    final widgetPos = _imageToWidget(state.textEditPosition!);
    final scale = widget.imageDisplayRect.width / widget.imagePixelSize.width;
    final widgetFontSize = state.settings.strokeWidth * 4 * scale;

    return Positioned(
      left: widgetPos.dx,
      top: widgetPos.dy,
      child: Material(
        type: MaterialType.transparency,
        child: IntrinsicWidth(
          child: KeyboardListener(
            focusNode: FocusNode(), // passive listener, real focus on TextField
            onKeyEvent: (event) {
              if (event is KeyDownEvent &&
                  event.logicalKey == LogicalKeyboardKey.escape) {
                _cancelTextEdit();
              }
            },
            child: TextField(
              controller: _textController,
              focusNode: _textFocusNode,
              autofocus: true,
              style: TextStyle(
                color: state.settings.color,
                fontSize: widgetFontSize,
                fontFamily: state.settings.fontFamily,
                height: 1.0,
                decoration: TextDecoration.none,
              ),
              cursorColor: state.settings.color,
              decoration: const InputDecoration(
                border: InputBorder.none,
                contentPadding: EdgeInsets.zero,
                isDense: true,
                isCollapsed: true,
              ),
              onSubmitted: (_) => _commitTextEdit(),
              onTapOutside: (_) {
                if (widget.annotationState.editingText) {
                  _commitTextEdit();
                }
              },
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.annotationState,
      builder: (context, _) {
        final movable =
            widget.annotationState.selectedAnnotation?.isText == true ||
            widget.annotationState.selectedAnnotation?.isStamp == true;
        final paint = MouseRegion(
          cursor: widget.enabled
              ? (movable ? SystemMouseCursors.move : SystemMouseCursors.precise)
              : MouseCursor.defer,
          child: CustomPaint(
            painter: _ScaledAnnotationPainter(
              annotations: widget.annotationState.annotations,
              activeAnnotation: widget.annotationState.activeAnnotation,
              selectedIndex: widget.annotationState.selectedIndex,
              imageDisplayRect: widget.imageDisplayRect,
              imagePixelSize: widget.imagePixelSize,
              sourceImage: widget.sourceImage,
              sourcePixels: _sourcePixels,
              sourceImageOffset: widget.sourceImageOffset,
            ),
            size: Size.infinite,
          ),
        );

        final content = Stack(children: [paint, _buildTextEditOverlay()]);

        if (!widget.handlePointerEvents) return content;

        return Listener(
          onPointerDown: widget.enabled ? _onPointerDown : null,
          onPointerMove: widget.enabled ? _onPointerMove : null,
          onPointerUp: widget.enabled ? _onPointerUp : null,
          behavior: HitTestBehavior.translucent,
          child: content,
        );
      },
    );
  }
}

/// Paints annotations in widget coordinates by applying a scale transform
/// from image pixel space to the displayed image rect.
class _ScaledAnnotationPainter extends CustomPainter {
  final List<Annotation> annotations;
  final Annotation? activeAnnotation;
  final int? selectedIndex;
  final Rect imageDisplayRect;
  final Size imagePixelSize;
  final ui.Image? sourceImage;
  final ByteData? sourcePixels;
  final Offset sourceImageOffset;

  _ScaledAnnotationPainter({
    required this.annotations,
    this.activeAnnotation,
    this.selectedIndex,
    required this.imageDisplayRect,
    required this.imagePixelSize,
    this.sourceImage,
    this.sourcePixels,
    this.sourceImageOffset = Offset.zero,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (annotations.isEmpty && activeAnnotation == null) return;

    // Clip to the image display area.
    canvas.save();
    canvas.clipRect(imageDisplayRect);

    // Transform from image pixel coordinates to widget coordinates.
    canvas.translate(imageDisplayRect.left, imageDisplayRect.top);
    canvas.scale(
      imageDisplayRect.width / imagePixelSize.width,
      imageDisplayRect.height / imagePixelSize.height,
    );

    // Delegate to the shared painter.
    final painter = AnnotationPainter(
      annotations: annotations,
      activeAnnotation: activeAnnotation,
      selectedIndex: selectedIndex,
      sourceImage: sourceImage,
      sourcePixels: sourcePixels,
      sourceImageOffset: sourceImageOffset,
    );
    painter.paint(canvas, imagePixelSize);

    canvas.restore();
  }

  @override
  bool shouldRepaint(_ScaledAnnotationPainter oldDelegate) {
    return !identical(annotations, oldDelegate.annotations) ||
        activeAnnotation != oldDelegate.activeAnnotation ||
        selectedIndex != oldDelegate.selectedIndex ||
        imageDisplayRect != oldDelegate.imageDisplayRect ||
        !identical(sourceImage, oldDelegate.sourceImage) ||
        !identical(sourcePixels, oldDelegate.sourcePixels) ||
        sourceImageOffset != oldDelegate.sourceImageOffset;
  }
}
