import 'dart:ui';

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

  x = x.clamp(0.0, screenSize.width - kToolbarSize.width);
  return Rect.fromLTWH(x, y, kToolbarSize.width, kToolbarSize.height);
}

Rect computeToolbarRectBelowWindow({
  required Rect windowRect,
  required Rect screenRect,
}) {
  var x = windowRect.center.dx - kToolbarSize.width / 2;
  x = x.clamp(screenRect.left, screenRect.right - kToolbarSize.width);

  final minY = windowRect.bottom + kToolbarGap;
  final maxY = screenRect.bottom - kToolbarSize.height;
  final y = minY <= maxY ? minY : maxY;

  return Rect.fromLTWH(x, y, kToolbarSize.width, kToolbarSize.height);
}
