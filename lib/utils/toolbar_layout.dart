import 'dart:ui';

/// Must stay in sync with the native toolbar panel size in
/// MainFlutterWindow.swift (ToolbarContentView).
const Size kToolbarSize = Size(536, 44);
const double kToolbarGap = 8.0;

/// Compute a toolbar rect relative to [anchorRect].
///
/// Priority: below anchor → above anchor → inside (bottom edge), with
/// horizontal clamping to keep the toolbar on-screen.
Rect computeToolbarRect({required Rect anchorRect, required Size screenSize}) {
  var x = anchorRect.center.dx - kToolbarSize.width / 2;
  double y;

  final belowY = anchorRect.bottom + kToolbarGap;
  final aboveY = anchorRect.top - kToolbarSize.height - kToolbarGap;

  if (belowY + kToolbarSize.height <= screenSize.height) {
    y = belowY;
  } else if (aboveY >= 0) {
    y = aboveY;
  } else {
    y = anchorRect.bottom - kToolbarSize.height - kToolbarGap;
    if (y < anchorRect.top + kToolbarGap) {
      y = anchorRect.top + kToolbarGap;
    }
  }

  final maxX = screenSize.width - kToolbarSize.width;
  if (maxX <= 0) {
    x = 0.0;
  } else {
    x = x.clamp(0.0, maxX);
  }
  return Rect.fromLTWH(x, y, kToolbarSize.width, kToolbarSize.height);
}

Rect computeToolbarRectBelowWindow({
  required Rect windowRect,
  required Rect screenRect,
}) {
  var x = windowRect.center.dx - kToolbarSize.width / 2;
  final minX = screenRect.left;
  final maxX = screenRect.right - kToolbarSize.width;
  if (maxX <= minX) {
    x = minX;
  } else {
    x = x.clamp(minX, maxX);
  }

  final minY = windowRect.bottom + kToolbarGap;
  final maxY = screenRect.bottom - kToolbarSize.height;
  final y = (minY <= maxY ? minY : maxY).clamp(screenRect.top, maxY);

  return Rect.fromLTWH(x, y, kToolbarSize.width, kToolbarSize.height);
}
