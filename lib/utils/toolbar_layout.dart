import 'package:flutter/painting.dart';

/// Reference toolbar footprint for placement calculations.
///
/// The visual toolbar can be scaled down by callers when available width is
/// smaller, but placement still starts from this baseline size.
const Size kToolbarSize = Size(536, 44);
const double kToolbarGap = 8.0;

/// Compute the native floating toolbar footprint used by the macOS panel.
///
/// Keep this in sync with `MainFlutterWindow.toolbarPanelSize()`.
Size computeNativeToolbarSize({
  required bool showPin,
  required bool showHistoryControls,
  required bool showOcr,
}) {
  const buttonWidth = 22.0;
  const separatorWidth = 1.0;
  const spacing = 4.0;
  const horizontalPadding = 16.0; // root leading/trailing = 8 + 8

  var viewCount = 9; // drawing tools
  var widthSum = 9 * buttonWidth;

  if (showOcr) {
    viewCount += 1;
    widthSum += buttonWidth;
  }

  if (showHistoryControls) {
    viewCount += 3; // separator + undo + redo
    widthSum += separatorWidth + (2 * buttonWidth);
  }

  viewCount += 1; // separator before action buttons
  widthSum += separatorWidth;

  var actionCount = 3; // copy + save + close
  if (showPin) {
    actionCount += 1; // optional pin
  }
  viewCount += actionCount;
  widthSum += actionCount * buttonWidth;

  final gaps = (viewCount - 1).clamp(0, viewCount);
  final width = horizontalPadding + widthSum + (gaps * spacing);
  return Size(width.ceilToDouble(), kToolbarSize.height);
}

/// Compute a toolbar rect relative to [anchorRect].
///
/// Priority: below anchor → above anchor → inside (bottom edge), with
/// horizontal clamping to keep the toolbar on-screen.
Rect computeToolbarRect({
  required Rect anchorRect,
  required Size screenSize,
  Size toolbarSize = kToolbarSize,
}) {
  var x = anchorRect.center.dx - toolbarSize.width / 2;
  double y;

  final belowY = anchorRect.bottom + kToolbarGap;
  final aboveY = anchorRect.top - toolbarSize.height - kToolbarGap;

  if (belowY + toolbarSize.height <= screenSize.height) {
    y = belowY;
  } else if (aboveY >= 0) {
    y = aboveY;
  } else {
    y = anchorRect.bottom - toolbarSize.height - kToolbarGap;
    if (y < anchorRect.top + kToolbarGap) {
      y = anchorRect.top + kToolbarGap;
    }
  }

  final maxX = screenSize.width - toolbarSize.width;
  if (maxX <= 0) {
    x = 0.0;
  } else {
    x = x.clamp(0.0, maxX);
  }
  return Rect.fromLTWH(x, y, toolbarSize.width, toolbarSize.height);
}

/// Compute a floating toolbar rect outside [anchorRect].
///
/// Keeps the toolbar below [anchorRect] and clamps it into the visible
/// viewport bounds.
///
/// Unlike [computeToolbarRect], this helper intentionally does not flip above
/// the anchor when vertical space is tight, which avoids jumpy movement during
/// interactive scrolling.
Rect computeFloatingToolbarRect({
  required Rect anchorRect,
  required Size screenSize,
  Size toolbarSize = kToolbarSize,
  EdgeInsets viewportPadding = const EdgeInsets.all(8),
}) {
  final minX = viewportPadding.left;
  final maxX = screenSize.width - viewportPadding.right - toolbarSize.width;
  final minY = viewportPadding.top;
  final maxY = screenSize.height - viewportPadding.bottom - toolbarSize.height;

  double x;
  if (maxX <= minX) {
    x = minX;
  } else {
    x = (anchorRect.center.dx - toolbarSize.width / 2).clamp(minX, maxX);
  }

  // Keep toolbar floating below anchor (never jump above).
  final y = (anchorRect.bottom + kToolbarGap).clamp(minY, maxY);

  return Rect.fromLTWH(x, y, toolbarSize.width, toolbarSize.height);
}

Rect computeToolbarRectBelowWindow({
  required Rect windowRect,
  required Rect screenRect,
  Size toolbarSize = kToolbarSize,
  EdgeInsets viewportPadding = EdgeInsets.zero,
}) {
  var x = windowRect.center.dx - toolbarSize.width / 2;
  final minX = screenRect.left + viewportPadding.left;
  final maxX = screenRect.right - viewportPadding.right - toolbarSize.width;
  if (maxX <= minX) {
    x = minX;
  } else {
    x = x.clamp(minX, maxX);
  }

  final minY = windowRect.bottom + kToolbarGap;
  final viewportTop = screenRect.top + viewportPadding.top;
  final maxY = screenRect.bottom - viewportPadding.bottom - toolbarSize.height;
  final y = maxY <= viewportTop
      ? viewportTop
      : (minY <= maxY ? minY : maxY).clamp(viewportTop, maxY);

  return Rect.fromLTWH(x, y, toolbarSize.width, toolbarSize.height);
}
