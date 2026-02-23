import 'dart:math' as math;

import 'package:flutter/services.dart';

/// The 8 resize handles around a selection rectangle.
enum SelectionHandle {
  topLeft,
  topCenter,
  topRight,
  middleLeft,
  middleRight,
  bottomLeft,
  bottomCenter,
  bottomRight,
}

/// Returns the center point of [handle] on the given [selection] rect.
Offset handlePosition(SelectionHandle handle, Rect selection) {
  return switch (handle) {
    SelectionHandle.topLeft => selection.topLeft,
    SelectionHandle.topCenter => Offset(selection.center.dx, selection.top),
    SelectionHandle.topRight => selection.topRight,
    SelectionHandle.middleLeft => Offset(selection.left, selection.center.dy),
    SelectionHandle.middleRight => Offset(selection.right, selection.center.dy),
    SelectionHandle.bottomLeft => selection.bottomLeft,
    SelectionHandle.bottomCenter => Offset(
      selection.center.dx,
      selection.bottom,
    ),
    SelectionHandle.bottomRight => selection.bottomRight,
  };
}

/// Hit-tests [point] against the 8 handles of [selection].
///
/// Returns the handle if [point] is within [hitRadius] of its center,
/// or null if no handle is hit. Corners are tested first so they take
/// priority over edges when overlapping at small selection sizes.
SelectionHandle? hitTestHandle(
  Offset point,
  Rect selection, {
  double hitRadius = 8,
}) {
  // Test corners first (more useful for small selections).
  const corners = [
    SelectionHandle.topLeft,
    SelectionHandle.topRight,
    SelectionHandle.bottomLeft,
    SelectionHandle.bottomRight,
  ];
  for (final handle in corners) {
    final center = handlePosition(handle, selection);
    if ((point - center).distance <= hitRadius) return handle;
  }

  // Then test edge midpoints.
  const edges = [
    SelectionHandle.topCenter,
    SelectionHandle.bottomCenter,
    SelectionHandle.middleLeft,
    SelectionHandle.middleRight,
  ];
  for (final handle in edges) {
    final center = handlePosition(handle, selection);
    if ((point - center).distance <= hitRadius) return handle;
  }

  return null;
}

/// Whether [handle] is one of the four corner handles.
bool isCornerHandle(SelectionHandle handle) => switch (handle) {
  SelectionHandle.topLeft ||
  SelectionHandle.topRight ||
  SelectionHandle.bottomLeft ||
  SelectionHandle.bottomRight => true,
  _ => false,
};

/// Returns the appropriate resize cursor for [handle].
MouseCursor cursorForHandle(SelectionHandle handle) {
  return switch (handle) {
    SelectionHandle.topLeft => SystemMouseCursors.resizeUpLeft,
    SelectionHandle.topRight => SystemMouseCursors.resizeUpRight,
    SelectionHandle.bottomLeft => SystemMouseCursors.resizeDownLeft,
    SelectionHandle.bottomRight => SystemMouseCursors.resizeDownRight,
    SelectionHandle.topCenter => SystemMouseCursors.resizeUp,
    SelectionHandle.bottomCenter => SystemMouseCursors.resizeDown,
    SelectionHandle.middleLeft => SystemMouseCursors.resizeLeft,
    SelectionHandle.middleRight => SystemMouseCursors.resizeRight,
  };
}

/// Computes a new selection rect after dragging [handle] by [delta] from
/// [original].
///
/// Enforces [minSize] minimum dimensions, clamps to [screenBounds], and
/// prevents the selection from flipping (left stays left of right, etc.).
Rect applyResize(
  SelectionHandle handle,
  Rect original,
  Offset delta,
  Size screenBounds, {
  double minSize = 10,
}) {
  var left = original.left;
  var top = original.top;
  var right = original.right;
  var bottom = original.bottom;

  // Adjust edges based on which handle is being dragged.
  switch (handle) {
    case SelectionHandle.topLeft:
      left += delta.dx;
      top += delta.dy;
    case SelectionHandle.topCenter:
      top += delta.dy;
    case SelectionHandle.topRight:
      right += delta.dx;
      top += delta.dy;
    case SelectionHandle.middleLeft:
      left += delta.dx;
    case SelectionHandle.middleRight:
      right += delta.dx;
    case SelectionHandle.bottomLeft:
      left += delta.dx;
      bottom += delta.dy;
    case SelectionHandle.bottomCenter:
      bottom += delta.dy;
    case SelectionHandle.bottomRight:
      right += delta.dx;
      bottom += delta.dy;
  }

  // Enforce minimum size — prevent the selection from collapsing or flipping.
  if (right - left < minSize) {
    // Determine which edge was being moved and pin the other.
    if (handle == SelectionHandle.topLeft ||
        handle == SelectionHandle.middleLeft ||
        handle == SelectionHandle.bottomLeft) {
      left = right - minSize;
    } else {
      right = left + minSize;
    }
  }
  if (bottom - top < minSize) {
    if (handle == SelectionHandle.topLeft ||
        handle == SelectionHandle.topCenter ||
        handle == SelectionHandle.topRight) {
      top = bottom - minSize;
    } else {
      bottom = top + minSize;
    }
  }

  // Clamp to screen bounds.
  left = math.max(0, left);
  top = math.max(0, top);
  right = math.min(screenBounds.width, right);
  bottom = math.min(screenBounds.height, bottom);

  // Re-check minimum size after clamping (edge case: dragging past screen edge).
  if (right - left < minSize) {
    if (left == 0) {
      right = minSize;
    } else {
      left = right - minSize;
    }
  }
  if (bottom - top < minSize) {
    if (top == 0) {
      bottom = minSize;
    } else {
      top = bottom - minSize;
    }
  }

  return Rect.fromLTRB(left, top, right, bottom);
}

/// Clamps [rect] so it stays entirely within (0,0)-(screenW, screenH).
Rect clampToScreen(Rect rect, Size screenBounds) {
  var left = rect.left;
  var top = rect.top;

  if (left < 0) left = 0;
  if (top < 0) top = 0;
  if (left + rect.width > screenBounds.width) {
    left = screenBounds.width - rect.width;
  }
  if (top + rect.height > screenBounds.height) {
    top = screenBounds.height - rect.height;
  }

  return Rect.fromLTWH(left, top, rect.width, rect.height);
}
