import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/selection_handle.dart';
import '../widgets/selection_toolbar.dart';

/// Internal phase of the selection interaction.
enum _SelectionPhase {
  /// No selection yet — crosshair, loupe, and window/element detection active.
  hovering,

  /// User is dragging to draw a new selection.
  drawing,

  /// Selection made — handles and toolbar visible.
  selected,

  /// A resize handle is being dragged.
  resizing,

  /// The selection is being moved by dragging inside it.
  moving,
}

/// Fullscreen overlay for region selection (Snipaste-style).
///
/// Displays the captured screenshot as an opaque background with a
/// semi-transparent scrim on top. Dragging draws a selection rectangle
/// that cuts through the scrim to reveal the original screenshot.
///
/// After a selection is drawn, 8 resize handles and a toolbar appear.
/// The user can resize, move, or redraw the selection, then use the
/// toolbar to copy, save, or cancel.
class RegionSelectionScreen extends StatefulWidget {
  /// Pre-decoded image for instant display (no async Image.memory decode).
  final ui.Image decodedImage;
  final List<Rect> windowRects;
  final VoidCallback onCancel;

  /// Callbacks for Snipaste-style toolbar actions (normal region capture).
  final void Function(Rect selectionRect)? onCopy;
  final void Function(Rect selectionRect)? onSave;

  /// Legacy callback for draw-once selection (scroll capture compatibility).
  final void Function(Rect selectionRect)? onRegionSelected;

  /// When true, uses the legacy draw-once behavior: pointer up fires
  /// [onRegionSelected] immediately with no handles or toolbar.
  /// Used by scroll capture which needs the rect to start capturing.
  final bool isScrollSelection;

  /// Real-time AX hit-test callback. Takes a local point, returns the deepest
  /// accessible element rect in local coordinates (or null).
  final Future<Rect?> Function(Offset localPoint)? onHitTest;

  const RegionSelectionScreen({
    super.key,
    required this.decodedImage,
    required this.windowRects,
    required this.onCancel,
    this.onCopy,
    this.onSave,
    this.onRegionSelected,
    this.onHitTest,
    this.isScrollSelection = false,
  });

  @override
  State<RegionSelectionScreen> createState() => _RegionSelectionScreenState();
}

class _RegionSelectionScreenState extends State<RegionSelectionScreen> {
  static const _channel = MethodChannel('com.asnap/window');
  final _focusNode = FocusNode();

  // -- Interaction state --
  _SelectionPhase _phase = _SelectionPhase.hovering;
  Offset _current = Offset.zero;

  // Drawing phase: start point for the initial drag.
  Offset? _drawStart;

  // Selected/resizing/moving phases: the current selection rectangle.
  Rect? _selectionRect;

  // Resizing state.
  SelectionHandle? _activeHandle;
  Offset? _dragStartOffset;
  Rect? _dragStartRect;

  // Hovering phase: detected window/element under cursor.
  Rect? _detectedWindowRect;

  /// True while a platform-channel AX hit-test is in flight.
  bool _axQueryInFlight = false;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  /// Computed selection rect during drawing phase (from two points).
  Rect? get _drawingRect {
    if (_drawStart == null) return null;
    return Rect.fromPoints(_drawStart!, _current);
  }

  /// The rect to display: finalized selection or in-progress drawing.
  Rect? get _displayRect {
    if (_phase == _SelectionPhase.drawing) return _drawingRect;
    return _selectionRect;
  }

  bool get _showHandles =>
      _phase == _SelectionPhase.selected ||
      _phase == _SelectionPhase.resizing ||
      _phase == _SelectionPhase.moving;

  // -----------------------------------------------------------------------
  // Hit testing
  // -----------------------------------------------------------------------

  Rect? _hitTestElement(Offset point) {
    Rect? best;
    double bestArea = double.infinity;
    for (final rect in widget.windowRects) {
      if (rect.contains(point)) {
        final area = rect.width * rect.height;
        if (area < bestArea) {
          bestArea = area;
          best = rect;
        }
      }
    }
    return best;
  }

  Future<void> _fireAxHitTest(Offset queryPoint) async {
    try {
      final rect = await widget.onHitTest?.call(queryPoint);
      if (!mounted || _phase != _SelectionPhase.hovering) return;
      final effective = rect ?? _hitTestElement(_current);
      if (effective != _detectedWindowRect) {
        setState(() {
          _detectedWindowRect = effective;
        });
      }
    } finally {
      _axQueryInFlight = false;
      if (mounted &&
          _phase == _SelectionPhase.hovering &&
          widget.onHitTest != null) {
        if ((_current - queryPoint).distance > 5) {
          _axQueryInFlight = true;
          unawaited(_fireAxHitTest(_current));
        }
      }
    }
  }

  // -----------------------------------------------------------------------
  // Pointer events
  // -----------------------------------------------------------------------

  void _onPointerDown(PointerDownEvent event) {
    // Right-click → go back one step (Snipaste-style).
    if ((event.buttons & kSecondaryMouseButton) != 0) {
      _goBack();
      return;
    }

    final pos = event.localPosition;

    switch (_phase) {
      case _SelectionPhase.hovering:
        // Start drawing a new selection.
        setState(() {
          _drawStart = pos;
          _current = pos;
          _phase = _SelectionPhase.drawing;
          // Keep _detectedWindowRect for potential click selection.
        });

      case _SelectionPhase.selected:
        // Check handles first.
        if (_selectionRect != null) {
          final handle = hitTestHandle(pos, _selectionRect!);
          if (handle != null) {
            setState(() {
              _phase = _SelectionPhase.resizing;
              _activeHandle = handle;
              _dragStartOffset = pos;
              _dragStartRect = _selectionRect;
            });
            // Set native diagonal cursor for corner resizing (Flutter's
            // SystemMouseCursors don't work for diagonals on macOS).
            if (isCornerHandle(handle)) {
              _setNativeDiagonalCursor(handle);
            }
            return;
          }
          // Inside selection -> move.
          if (_selectionRect!.contains(pos)) {
            setState(() {
              _phase = _SelectionPhase.moving;
              _dragStartOffset = pos;
              _dragStartRect = _selectionRect;
            });
            return;
          }
        }
        // Outside selection -> start a new one.
        setState(() {
          _selectionRect = null;
          _drawStart = pos;
          _current = pos;
          _phase = _SelectionPhase.drawing;
        });

      case _SelectionPhase.drawing:
      case _SelectionPhase.resizing:
      case _SelectionPhase.moving:
        // Already in a drag — ignore additional pointer downs.
        break;
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    final pos = event.localPosition;
    final screenSize = MediaQuery.sizeOf(context);

    switch (_phase) {
      case _SelectionPhase.drawing:
        setState(() {
          _current = pos;
        });

      case _SelectionPhase.resizing:
        if (_dragStartOffset != null && _dragStartRect != null) {
          final delta = pos - _dragStartOffset!;
          setState(() {
            _selectionRect = applyResize(
              _activeHandle!,
              _dragStartRect!,
              delta,
              screenSize,
            );
            _current = pos;
          });
        }

      case _SelectionPhase.moving:
        if (_dragStartOffset != null && _dragStartRect != null) {
          final delta = pos - _dragStartOffset!;
          final moved = _dragStartRect!.shift(delta);
          setState(() {
            _selectionRect = clampToScreen(moved, screenSize);
            _current = pos;
          });
        }

      case _SelectionPhase.hovering:
      case _SelectionPhase.selected:
        break;
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    switch (_phase) {
      case _SelectionPhase.drawing:
        _finishDrawing(event.localPosition);

      case _SelectionPhase.resizing:
      case _SelectionPhase.moving:
        setState(() {
          _phase = _SelectionPhase.selected;
          _activeHandle = null;
          _dragStartOffset = null;
          _dragStartRect = null;
        });

      case _SelectionPhase.hovering:
      case _SelectionPhase.selected:
        break;
    }
  }

  void _finishDrawing(Offset upPosition) {
    final rect = _drawingRect;
    if (rect != null && rect.width.abs() > 4 && rect.height.abs() > 4) {
      // Normalize to positive rect.
      final normalized = Rect.fromLTRB(
        rect.left < rect.right ? rect.left : rect.right,
        rect.top < rect.bottom ? rect.top : rect.bottom,
        rect.left < rect.right ? rect.right : rect.left,
        rect.top < rect.bottom ? rect.bottom : rect.top,
      );

      if (widget.isScrollSelection) {
        // Legacy path: fire callback immediately.
        widget.onRegionSelected?.call(normalized);
      } else {
        // Snipaste-style: transition to selected with handles.
        setState(() {
          _selectionRect = normalized;
          _drawStart = null;
          _phase = _SelectionPhase.selected;
        });
      }
    } else {
      // Click (no meaningful drag) — accept detected window or AX element.
      final detected = _detectedWindowRect;
      final clickPos = upPosition;
      final windowRect = (detected != null && detected.contains(clickPos))
          ? detected
          : _hitTestElement(clickPos);

      if (windowRect != null) {
        if (widget.isScrollSelection) {
          widget.onRegionSelected?.call(windowRect);
        } else {
          setState(() {
            _selectionRect = windowRect;
            _drawStart = null;
            _phase = _SelectionPhase.selected;
          });
        }
      } else if (widget.onHitTest != null) {
        unawaited(_tryAxClickSelect(clickPos));
      } else {
        setState(() {
          _drawStart = null;
          _phase = _SelectionPhase.hovering;
        });
      }
    }
  }

  Future<void> _tryAxClickSelect(Offset localPoint) async {
    final rect = await widget.onHitTest?.call(localPoint);
    if (!mounted) return;
    if (rect != null) {
      if (widget.isScrollSelection) {
        widget.onRegionSelected?.call(rect);
      } else {
        setState(() {
          _selectionRect = rect;
          _drawStart = null;
          _phase = _SelectionPhase.selected;
        });
      }
    } else {
      setState(() {
        _drawStart = null;
        _phase = _SelectionPhase.hovering;
      });
    }
  }

  // -----------------------------------------------------------------------
  // Keyboard
  // -----------------------------------------------------------------------

  void _onKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return;
    if (event.logicalKey != LogicalKeyboardKey.escape) return;
    // Escape always exits the overlay immediately — no multi-step unwind.
    widget.onCancel();
  }

  /// Go back one step (right-click behavior).
  ///
  /// Hovering → exit overlay. Drawing → cancel draw. Selected → clear
  /// selection. Resizing/Moving → restore original rect.
  void _goBack() {
    switch (_phase) {
      case _SelectionPhase.hovering:
        widget.onCancel();

      case _SelectionPhase.drawing:
        setState(() {
          _drawStart = null;
          _phase = _SelectionPhase.hovering;
        });

      case _SelectionPhase.selected:
        setState(() {
          _selectionRect = null;
          _phase = _SelectionPhase.hovering;
        });

      case _SelectionPhase.resizing:
      case _SelectionPhase.moving:
        setState(() {
          _selectionRect = _dragStartRect;
          _activeHandle = null;
          _dragStartOffset = null;
          _dragStartRect = null;
          _phase = _SelectionPhase.selected;
        });
    }
  }

  // -----------------------------------------------------------------------
  // Cursor
  // -----------------------------------------------------------------------

  MouseCursor get _currentCursor {
    switch (_phase) {
      case _SelectionPhase.hovering:
      case _SelectionPhase.drawing:
        return SystemMouseCursors.precise;

      case _SelectionPhase.resizing:
        // Corner handles use native diagonal cursors (Flutter's macOS
        // implementation silently falls back to the arrow cursor).
        if (isCornerHandle(_activeHandle!)) return MouseCursor.uncontrolled;
        return cursorForHandle(_activeHandle!);

      case _SelectionPhase.moving:
        return SystemMouseCursors.move;

      case _SelectionPhase.selected:
        if (_selectionRect == null) return SystemMouseCursors.precise;
        final handle = hitTestHandle(_current, _selectionRect!);
        if (handle != null) {
          if (isCornerHandle(handle)) return MouseCursor.uncontrolled;
          return cursorForHandle(handle);
        }
        if (_selectionRect!.contains(_current)) return SystemMouseCursors.move;
        return SystemMouseCursors.precise;
    }
  }

  /// Set a diagonal resize cursor via native macOS API.
  ///
  /// Flutter's `SystemMouseCursors.resizeUpLeft` etc. don't work on macOS,
  /// so we call the private NSCursor API directly through the platform channel.
  void _setNativeDiagonalCursor(SelectionHandle handle) {
    final type = switch (handle) {
      SelectionHandle.topLeft || SelectionHandle.bottomRight => 'nwse',
      SelectionHandle.topRight || SelectionHandle.bottomLeft => 'nesw',
      _ => null,
    };
    if (type != null) {
      unawaited(_channel.invokeMethod('setResizeCursor', {'type': type}));
    }
  }

  // -----------------------------------------------------------------------
  // Toolbar positioning
  // -----------------------------------------------------------------------

  /// Compute toolbar position relative to the selection rect.
  /// Priority: below selection → above selection → inside (bottom edge).
  /// Returns null if no selection exists.
  Offset? _toolbarOffset(Size screenSize) {
    final sel = _selectionRect;
    if (sel == null) return null;

    // Estimate toolbar size (3 buttons * 34px + 2 gaps * 4px + padding 16px).
    const toolbarWidth = 130.0;
    const toolbarHeight = 42.0;
    const gap = 8.0;

    var x = sel.center.dx - toolbarWidth / 2;
    double y;

    final belowY = sel.bottom + gap;
    final aboveY = sel.top - toolbarHeight - gap;

    if (belowY + toolbarHeight <= screenSize.height) {
      // Fits below the selection.
      y = belowY;
    } else if (aboveY >= 0) {
      // Fits above the selection.
      y = aboveY;
    } else {
      // Neither above nor below works — place inside the selection,
      // anchored to the bottom edge with an inset.
      y = sel.bottom - toolbarHeight - gap;
      // Ensure it doesn't go above the selection top.
      if (y < sel.top + gap) {
        y = sel.top + gap;
      }
    }

    // Clamp horizontally.
    x = x.clamp(0, screenSize.width - toolbarWidth);

    return Offset(x, y);
  }

  // -----------------------------------------------------------------------
  // Toolbar actions
  // -----------------------------------------------------------------------

  void _handleToolbarCopy() {
    if (_selectionRect == null) return;
    widget.onCopy?.call(_selectionRect!);
  }

  void _handleToolbarSave() {
    if (_selectionRect == null) return;
    widget.onSave?.call(_selectionRect!);
  }

  void _handleToolbarClose() {
    widget.onCancel();
  }

  // -----------------------------------------------------------------------
  // Build
  // -----------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);

    return KeyboardListener(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _onKeyEvent,
      child: MouseRegion(
        cursor: _currentCursor,
        onHover: (event) {
          if (event.localPosition == _current) return;
          final pos = event.localPosition;
          setState(() {
            _current = pos;
          });

          // Set native diagonal cursor for corner handles (Flutter's macOS
          // implementation doesn't support diagonal resize cursors).
          if (_phase == _SelectionPhase.selected && _selectionRect != null) {
            final handle = hitTestHandle(pos, _selectionRect!);
            if (handle != null && isCornerHandle(handle)) {
              _setNativeDiagonalCursor(handle);
            }
          }

          // Only fire AX/geometric hit tests during hovering phase.
          if (_phase == _SelectionPhase.hovering) {
            final hasAxHitTest = widget.onHitTest != null;
            if (!hasAxHitTest) {
              setState(() {
                _detectedWindowRect = _hitTestElement(pos);
              });
            } else if (!_axQueryInFlight) {
              _axQueryInFlight = true;
              unawaited(_fireAxHitTest(pos));
            }
          }
        },
        child: Stack(
          children: [
            // Listener wraps ONLY the canvas — toolbar sits as a sibling
            // so toolbar clicks are not intercepted by _onPointerDown.
            Positioned.fill(
              child: Listener(
                onPointerDown: _onPointerDown,
                onPointerMove: _onPointerMove,
                onPointerUp: _onPointerUp,
                child: CustomPaint(
                  painter: _SelectionPainter(
                    backgroundImage: widget.decodedImage,
                    selectionRect: _displayRect,
                    detectedWindowRect: _phase == _SelectionPhase.hovering
                        ? _detectedWindowRect
                        : null,
                    cursorPosition: _current,
                    isDrawing:
                        _phase == _SelectionPhase.hovering ||
                        _phase == _SelectionPhase.drawing,
                    showHandles: _showHandles,
                    devicePixelRatio: dpr,
                    screenSize: screenSize,
                  ),
                  isComplex: true,
                  willChange: true,
                ),
              ),
            ),

            // Toolbar (only visible in selected phase) — outside the
            // Listener so clicks reach the buttons without interference.
            if (_phase == _SelectionPhase.selected &&
                _selectionRect != null) ...[
              Builder(
                builder: (context) {
                  final offset = _toolbarOffset(screenSize);
                  if (offset == null) return const SizedBox.shrink();
                  return Positioned(
                    left: offset.dx,
                    top: offset.dy,
                    child: SelectionToolbar(
                      onCopy: _handleToolbarCopy,
                      onSave: _handleToolbarSave,
                      onClose: _handleToolbarClose,
                    ),
                  );
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Painter
// ---------------------------------------------------------------------------

class _SelectionPainter extends CustomPainter {
  static const double _loupeSize = 140;
  static const double _loupeZoom = 8;
  static const double _loupeCursorOffset = 20;
  static const double _handleSize = 8;

  final ui.Image backgroundImage;
  final Rect? selectionRect;
  final Rect? detectedWindowRect;
  final Offset cursorPosition;

  /// True when in hovering/drawing phase (show crosshair + loupe).
  final bool isDrawing;

  /// True when handles should be drawn around the selection.
  final bool showHandles;

  final double devicePixelRatio;
  final Size screenSize;

  _SelectionPainter({
    required this.backgroundImage,
    required this.selectionRect,
    required this.detectedWindowRect,
    required this.cursorPosition,
    required this.isDrawing,
    required this.showHandles,
    required this.devicePixelRatio,
    required this.screenSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final fullRect = Rect.fromLTWH(0, 0, size.width, size.height);

    canvas.saveLayer(fullRect, Paint()..blendMode = BlendMode.src);
    canvas.drawRect(fullRect, Paint()..color = Colors.black);

    // Paint the captured screenshot.
    final imageSize = Size(
      backgroundImage.width.toDouble(),
      backgroundImage.height.toDouble(),
    );
    final fitted = applyBoxFit(BoxFit.cover, imageSize, size);
    final srcRect = Alignment.center.inscribe(
      fitted.source,
      Offset.zero & imageSize,
    );
    final dstRect = Alignment.center.inscribe(
      fitted.destination,
      Offset.zero & size,
    );
    canvas.drawImageRect(backgroundImage, srcRect, dstRect, Paint());

    // Semi-transparent scrim.
    final scrimPaint = Paint()..color = const Color(0x44000000);

    if (selectionRect != null) {
      // Scrim with cutout.
      final fullPath = Path()..addRect(fullRect);
      final selPath = Path()..addRect(selectionRect!);
      final scrimPath = Path.combine(
        PathOperation.difference,
        fullPath,
        selPath,
      );
      canvas.drawPath(scrimPath, scrimPaint);

      // Selection border.
      final borderPaint = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1;
      canvas.drawRect(selectionRect!, borderPaint);

      // Dimension label.
      final w = (selectionRect!.width.abs() * devicePixelRatio).round();
      final h = (selectionRect!.height.abs() * devicePixelRatio).round();
      _drawDimensionLabel(canvas, selectionRect!, '$w \u00D7 $h', size);

      // Handles.
      if (showHandles) {
        _drawHandles(canvas, selectionRect!);
      }
    } else if (detectedWindowRect != null) {
      // Window detection highlight.
      final fullPath = Path()..addRect(fullRect);
      final windowPath = Path()..addRect(detectedWindowRect!);
      final scrimPath = Path.combine(
        PathOperation.difference,
        fullPath,
        windowPath,
      );
      canvas.drawPath(scrimPath, scrimPaint);

      final borderPaint = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      canvas.drawRect(detectedWindowRect!, borderPaint);

      final w = (detectedWindowRect!.width * devicePixelRatio).round();
      final h = (detectedWindowRect!.height * devicePixelRatio).round();
      _drawDimensionLabel(canvas, detectedWindowRect!, '$w \u00D7 $h', size);
    } else {
      canvas.drawRect(fullRect, scrimPaint);
    }

    // Crosshair + loupe only during hovering/drawing phases.
    if (isDrawing) {
      _drawCrosshair(canvas, size);
      _paintLoupe(canvas);
    }

    canvas.restore();
  }

  void _drawHandles(Canvas canvas, Rect selection) {
    final fillPaint = Paint()..color = Colors.white;
    final borderPaint = Paint()
      ..color = const Color(0xFF333333)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    for (final handle in SelectionHandle.values) {
      final center = handlePosition(handle, selection);
      final rect = Rect.fromCenter(
        center: center,
        width: _handleSize,
        height: _handleSize,
      );
      canvas.drawRect(rect, fillPaint);
      canvas.drawRect(rect, borderPaint);
    }
  }

  void _drawCrosshair(Canvas canvas, Size size) {
    final shadowPaint = Paint()
      ..color = const Color(0x55000000)
      ..strokeWidth = 1;
    final crosshairPaint = Paint()
      ..color = const Color(0xAAFFFFFF)
      ..strokeWidth = 0.5;

    canvas.drawLine(
      Offset(0, cursorPosition.dy),
      Offset(size.width, cursorPosition.dy),
      shadowPaint,
    );
    canvas.drawLine(
      Offset(0, cursorPosition.dy),
      Offset(size.width, cursorPosition.dy),
      crosshairPaint,
    );
    canvas.drawLine(
      Offset(cursorPosition.dx, 0),
      Offset(cursorPosition.dx, size.height),
      shadowPaint,
    );
    canvas.drawLine(
      Offset(cursorPosition.dx, 0),
      Offset(cursorPosition.dx, size.height),
      crosshairPaint,
    );
  }

  void _paintLoupe(Canvas canvas) {
    final loupeOffset = _computeLoupeOffset();
    final loupeRect = Rect.fromLTWH(
      loupeOffset.dx,
      loupeOffset.dy,
      _loupeSize,
      _loupeSize,
    );
    final loupeRRect = RRect.fromRectAndRadius(
      loupeRect,
      const Radius.circular(8),
    );

    final loupePath = Path()..addRRect(loupeRRect);
    canvas.drawShadow(loupePath, const Color(0x80000000), 6, true);

    canvas.save();
    canvas.clipRRect(loupeRRect);

    final sampleSize = _loupeSize * devicePixelRatio / _loupeZoom;
    final physX = cursorPosition.dx * devicePixelRatio;
    final physY = cursorPosition.dy * devicePixelRatio;
    final srcRect = Rect.fromCenter(
      center: Offset(physX, physY),
      width: sampleSize,
      height: sampleSize,
    );
    final clampedSrc = Rect.fromLTRB(
      srcRect.left.clamp(0, backgroundImage.width.toDouble()),
      srcRect.top.clamp(0, backgroundImage.height.toDouble()),
      srcRect.right.clamp(0, backgroundImage.width.toDouble()),
      srcRect.bottom.clamp(0, backgroundImage.height.toDouble()),
    );
    canvas.drawImageRect(
      backgroundImage,
      clampedSrc,
      loupeRect,
      Paint()..filterQuality = FilterQuality.none,
    );

    final center = loupeRect.center;
    final loupeShadow = Paint()
      ..color = const Color(0x99000000)
      ..strokeWidth = 1.5;
    final loupeCrosshair = Paint()
      ..color = const Color(0xCCFFFFFF)
      ..strokeWidth = 0.5;
    canvas.drawLine(
      Offset(loupeRect.left, center.dy),
      Offset(loupeRect.right, center.dy),
      loupeShadow,
    );
    canvas.drawLine(
      Offset(center.dx, loupeRect.top),
      Offset(center.dx, loupeRect.bottom),
      loupeShadow,
    );
    canvas.drawLine(
      Offset(loupeRect.left, center.dy),
      Offset(loupeRect.right, center.dy),
      loupeCrosshair,
    );
    canvas.drawLine(
      Offset(center.dx, loupeRect.top),
      Offset(center.dx, loupeRect.bottom),
      loupeCrosshair,
    );

    canvas.restore();

    final borderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawRRect(loupeRRect, borderPaint);

    final physicalX = (cursorPosition.dx * devicePixelRatio).round();
    final physicalY = (cursorPosition.dy * devicePixelRatio).round();
    _drawLoupeLabel(
      canvas,
      Offset(loupeRect.left, loupeRect.bottom + 4),
      Size(_loupeSize, 20),
      '$physicalX, $physicalY',
    );
  }

  Offset _computeLoupeOffset() {
    var dx = cursorPosition.dx + _loupeCursorOffset;
    var dy = cursorPosition.dy - _loupeSize / 2 - 16;

    if (dx + _loupeSize > screenSize.width) {
      dx = cursorPosition.dx - _loupeCursorOffset - _loupeSize;
    }
    if (dy < 0) {
      dy = cursorPosition.dy + _loupeCursorOffset;
    }
    dx = dx.clamp(0, screenSize.width - _loupeSize);
    dy = dy.clamp(0, screenSize.height - _loupeSize - 24);

    return Offset(dx, dy);
  }

  void _drawLoupeLabel(Canvas canvas, Offset topLeft, Size size, String text) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final bgW = tp.width + 16;
    final bgH = tp.height + 6;
    final bgX = topLeft.dx + (size.width - bgW) / 2;
    final bgRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(bgX, topLeft.dy, bgW, bgH),
      const Radius.circular(4),
    );
    canvas.drawRRect(bgRect, Paint()..color = const Color(0xCC000000));
    tp.paint(canvas, Offset(bgX + 8, topLeft.dy + 3));
  }

  void _drawDimensionLabel(
    Canvas canvas,
    Rect selection,
    String text,
    Size canvasSize,
  ) {
    final textPainter = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final labelW = textPainter.width + 12;
    final labelH = textPainter.height + 6;
    final labelX = selection.center.dx - labelW / 2;
    var labelY = selection.bottom + 6;

    if (labelY + labelH > canvasSize.height) {
      labelY = selection.top - labelH - 6;
    }

    final bgRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(labelX, labelY, labelW, labelH),
      const Radius.circular(4),
    );
    canvas.drawRRect(bgRect, Paint()..color = const Color(0xCC000000));
    textPainter.paint(canvas, Offset(labelX + 6, labelY + 3));
  }

  @override
  bool shouldRepaint(_SelectionPainter oldDelegate) {
    return selectionRect != oldDelegate.selectionRect ||
        detectedWindowRect != oldDelegate.detectedWindowRect ||
        cursorPosition != oldDelegate.cursorPosition ||
        isDrawing != oldDelegate.isDrawing ||
        showHandles != oldDelegate.showHandles ||
        screenSize != oldDelegate.screenSize;
  }
}
