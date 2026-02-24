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

  const AnnotationOverlay({
    super.key,
    required this.annotationState,
    required this.imageDisplayRect,
    required this.imagePixelSize,
    required this.enabled,
    this.handlePointerEvents = true,
  });

  @override
  State<AnnotationOverlay> createState() => _AnnotationOverlayState();
}

class _AnnotationOverlayState extends State<AnnotationOverlay> {
  // Handle drag state.
  bool _draggingHandle = false;
  AnnHandle? _activeHandle;

  // Double-click detection.
  DateTime? _lastPointerDown;
  Offset? _lastPointerDownPos;

  Offset _widgetToImage(Offset widgetPoint) {
    final scaleX = widget.imagePixelSize.width / widget.imageDisplayRect.width;
    final scaleY =
        widget.imagePixelSize.height / widget.imageDisplayRect.height;
    return Offset(
      (widgetPoint.dx - widget.imageDisplayRect.left) * scaleX,
      (widgetPoint.dy - widget.imageDisplayRect.top) * scaleY,
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
    }

    // 4. Check shape stroke hit → select.
    final hitIdx = hitTestAnnotations(imagePoint, state.annotations);
    if (hitIdx != null) {
      state.selectAnnotation(hitIdx);
      return;
    }

    // 5. Empty space → deselect, start new drawing.
    state.deselectAnnotation();
    state.startDrawing(imagePoint);
  }

  void _onPointerMove(PointerMoveEvent event) {
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
    if (_draggingHandle) {
      _draggingHandle = false;
      _activeHandle = null;
      widget.annotationState.commitEdit();
      return;
    }
    if (widget.annotationState.activeAnnotation == null) return;
    widget.annotationState.finishDrawing();
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

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.annotationState,
      builder: (context, _) {
        final paint = MouseRegion(
          cursor: widget.enabled
              ? SystemMouseCursors.precise
              : MouseCursor.defer,
          child: CustomPaint(
            painter: _ScaledAnnotationPainter(
              annotations: widget.annotationState.annotations,
              activeAnnotation: widget.annotationState.activeAnnotation,
              selectedIndex: widget.annotationState.selectedIndex,
              imageDisplayRect: widget.imageDisplayRect,
              imagePixelSize: widget.imagePixelSize,
            ),
            size: Size.infinite,
          ),
        );

        if (!widget.handlePointerEvents) return paint;

        return Listener(
          onPointerDown: widget.enabled ? _onPointerDown : null,
          onPointerMove: widget.enabled ? _onPointerMove : null,
          onPointerUp: widget.enabled ? _onPointerUp : null,
          behavior: HitTestBehavior.translucent,
          child: paint,
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

  _ScaledAnnotationPainter({
    required this.annotations,
    this.activeAnnotation,
    this.selectedIndex,
    required this.imageDisplayRect,
    required this.imagePixelSize,
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
    );
    painter.paint(canvas, imagePixelSize);

    canvas.restore();
  }

  @override
  bool shouldRepaint(_ScaledAnnotationPainter oldDelegate) {
    return !identical(annotations, oldDelegate.annotations) ||
        activeAnnotation != oldDelegate.activeAnnotation ||
        selectedIndex != oldDelegate.selectedIndex ||
        imageDisplayRect != oldDelegate.imageDisplayRect;
  }
}
