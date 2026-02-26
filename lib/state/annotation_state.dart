import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../models/annotation.dart';
import '../utils/path_simplify.dart';

/// Persisted drawing settings used when creating new annotations.
class DrawingSettings {
  final ShapeType shapeType;
  final Color color;
  final double strokeWidth;
  final double cornerRadius;
  final String? fontFamily;
  final MosaicMode mosaicMode;

  const DrawingSettings({
    this.shapeType = ShapeType.rectangle,
    this.color = const Color(0xFFFF0000),
    this.strokeWidth = 6.0,
    this.cornerRadius = 20,
    this.fontFamily,
    this.mosaicMode = MosaicMode.pixelate,
  });

  DrawingSettings copyWith({
    ShapeType? shapeType,
    Color? color,
    double? strokeWidth,
    double? cornerRadius,
    String? fontFamily,
    bool clearFontFamily = false,
    MosaicMode? mosaicMode,
  }) => DrawingSettings(
    shapeType: shapeType ?? this.shapeType,
    color: color ?? this.color,
    strokeWidth: strokeWidth ?? this.strokeWidth,
    cornerRadius: cornerRadius ?? this.cornerRadius,
    fontFamily: clearFontFamily ? null : (fontFamily ?? this.fontFamily),
    mosaicMode: mosaicMode ?? this.mosaicMode,
  );
}

/// Manages the annotation drawing state with full undo/redo support.
///
/// Separate from [AppState] — annotations are orthogonal to the capture
/// lifecycle and have different clear/dispose semantics.
class AnnotationState extends ChangeNotifier {
  /// Snapshot-based undo stack. Each entry is a complete list of annotations.
  final List<List<Annotation>> _history = [const []];
  int _historyIndex = 0;

  /// The shape currently being drawn (not yet committed).
  Annotation? _activeAnnotation;
  Annotation? get activeAnnotation => _activeAnnotation;

  /// Current drawing settings (persist across shapes).
  DrawingSettings _settings = const DrawingSettings();
  DrawingSettings get settings => _settings;

  /// Per-tool settings memory (preserved across tool switches).
  final Map<ShapeType, double> _toolStrokeWidth = {
    ShapeType.rectangle: 6.0,
    ShapeType.ellipse: 6.0,
    ShapeType.arrow: 6.0,
    ShapeType.line: 6.0,
    ShapeType.pencil: 6.0,
    ShapeType.marker: 6.0,
    ShapeType.text: 9.0, // 9 × 4 = 36px default
    ShapeType.mosaic: 8.0, // default block size / blur intensity
    ShapeType.number: 6.0, // 6 × 4 = 24px stamp radius
  };
  final Map<ShapeType, Color> _toolColor = {};
  final Map<ShapeType, MosaicMode> _toolMosaicMode = {};
  final Map<MosaicMode, Color> _mosaicModeColor = {};

  /// All committed annotations.
  List<Annotation> get annotations => _history[_historyIndex];

  /// Currently selected annotation index (for handle manipulation).
  int? _selectedIndex;
  int? get selectedIndex => _selectedIndex;
  Annotation? get selectedAnnotation =>
      _selectedIndex != null && _selectedIndex! < annotations.length
      ? annotations[_selectedIndex!]
      : null;

  /// Whether a handle drag edit is in progress.
  bool _editing = false;
  List<Annotation>? _preEditSnapshot;

  bool get canUndo => _historyIndex > 0;
  bool get canRedo => _historyIndex < _history.length - 1;
  bool get hasAnnotations =>
      annotations.isNotEmpty || _activeAnnotation != null;

  // ---------------------------------------------------------------------------
  // Number stamp
  // ---------------------------------------------------------------------------

  /// Computes the next stamp number: highest existing label + 1.
  int get _nextStampNumber =>
      annotations
          .where((a) => a.type == ShapeType.number)
          .fold(
            0,
            (best, a) => a.label != null && a.label! > best ? a.label! : best,
          ) +
      1;

  /// Places a number stamp at [point] and immediately commits it.
  void placeStamp(Offset point) {
    final stamp = Annotation(
      type: ShapeType.number,
      start: point,
      end: point,
      color: _settings.color,
      strokeWidth: _settings.strokeWidth,
      label: _nextStampNumber,
    );
    _commitAnnotation(stamp);
    _selectedIndex = annotations.length - 1;
  }

  // ---------------------------------------------------------------------------
  // Text editing
  // ---------------------------------------------------------------------------

  /// Whether inline text editing is active (TextField overlay shown).
  bool _editingText = false;
  bool get editingText => _editingText;

  /// Position in image coordinates where the text is being placed.
  Offset? _textEditPosition;
  Offset? get textEditPosition => _textEditPosition;

  /// Starts inline text editing at [point] (image pixel coordinates).
  void startTextEdit(Offset point) {
    _editingText = true;
    _textEditPosition = point;
    notifyListeners();
  }

  /// Commits the text annotation with the given [content].
  ///
  /// [boundingEnd] is the bottom-right of the text bounding box in image
  /// coordinates, computed by the overlay from the TextPainter layout.
  void commitText(String content, Offset boundingEnd) {
    if (!_editingText || _textEditPosition == null) return;
    _editingText = false;
    if (content.trim().isEmpty) {
      _textEditPosition = null;
      notifyListeners();
      return;
    }
    final annotation = Annotation(
      type: ShapeType.text,
      start: _textEditPosition!,
      end: boundingEnd,
      color: _settings.color,
      strokeWidth: _settings.strokeWidth,
      text: content,
      fontFamily: _settings.fontFamily,
    );
    _textEditPosition = null;
    _commitAnnotation(annotation);
    _selectedIndex = annotations.length - 1;
  }

  /// Cancels the current text editing session.
  void cancelTextEdit() {
    if (!_editingText) return;
    _editingText = false;
    _textEditPosition = null;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Drawing lifecycle
  // ---------------------------------------------------------------------------

  void startDrawing(Offset startPoint) {
    final isFreehand =
        _settings.shapeType == ShapeType.pencil ||
        _settings.shapeType == ShapeType.marker;
    final effectiveStrokeWidth = _settings.shapeType == ShapeType.marker
        ? _settings.strokeWidth * 3
        : _settings.strokeWidth;
    _activeAnnotation = Annotation(
      type: _settings.shapeType,
      start: startPoint,
      end: startPoint,
      color: _settings.color,
      strokeWidth: effectiveStrokeWidth,
      cornerRadius: _settings.cornerRadius,
      points: isFreehand ? [startPoint] : const [],
      mosaicMode: _settings.mosaicMode,
    );
    notifyListeners();
  }

  void updateDrawing(Offset currentPoint, {bool constrained = false}) {
    if (_activeAnnotation == null) return;
    if (_activeAnnotation!.isFreehand) {
      _activeAnnotation = _activeAnnotation!.appendPoint(currentPoint);
    } else {
      _activeAnnotation = _activeAnnotation!
          .withEnd(currentPoint)
          .withConstrained(constrained);
    }
    notifyListeners();
  }

  void finishDrawing() {
    if (_activeAnnotation == null) return;
    var annotation = _activeAnnotation!;
    _activeAnnotation = null;

    if (annotation.isFreehand) {
      // Need at least 2 points for a visible stroke.
      if (annotation.points.length < 2) {
        notifyListeners();
        return;
      }
      // Simplify path to reduce point count.
      annotation = annotation.withPoints(simplifyPath(annotation.points));
    } else {
      // Only commit if the shape has meaningful size.
      final rect = Rect.fromPoints(annotation.start, annotation.end);
      if (rect.width.abs() < 2 && rect.height.abs() < 2) {
        notifyListeners();
        return;
      }
    }

    _commitAnnotation(annotation);
    _selectedIndex = annotations.length - 1; // auto-select new shape
  }

  void cancelDrawing() {
    _activeAnnotation = null;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Undo / Redo
  // ---------------------------------------------------------------------------

  void undo() {
    if (!canUndo) return;
    _historyIndex--;
    _selectedIndex = null;
    notifyListeners();
  }

  void redo() {
    if (!canRedo) return;
    _historyIndex++;
    _selectedIndex = null;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Settings
  // ---------------------------------------------------------------------------

  void updateSettings(DrawingSettings newSettings) {
    final previous = _settings;
    const defaultSettings = DrawingSettings();
    // Save/restore per-tool color, strokeWidth, and mosaicMode when switching.
    if (newSettings.shapeType != previous.shapeType) {
      // Save current tool's settings.
      _toolStrokeWidth[previous.shapeType] = previous.strokeWidth;
      _toolColor[previous.shapeType] = previous.color;
      _toolMosaicMode[previous.shapeType] = previous.mosaicMode;
      if (previous.shapeType == ShapeType.mosaic) {
        _mosaicModeColor[previous.mosaicMode] = previous.color;
      }
      // Restore target tool's settings (fall back to defaults).
      final target = newSettings.shapeType;
      final restoredMosaicMode = _toolMosaicMode[target] ?? previous.mosaicMode;
      final restoredColor = target == ShapeType.mosaic
          ? (_mosaicModeColor[restoredMosaicMode] ??
                (_toolColor[target] ?? defaultSettings.color))
          : (_toolColor[target] ?? defaultSettings.color);
      newSettings = newSettings.copyWith(
        strokeWidth: _toolStrokeWidth[target] ?? defaultSettings.strokeWidth,
        color: restoredColor,
        mosaicMode: restoredMosaicMode,
      );
    }

    if (newSettings.shapeType == ShapeType.mosaic) {
      if (previous.shapeType == ShapeType.mosaic) {
        _mosaicModeColor[previous.mosaicMode] = previous.color;
      }
      final nextMode = newSettings.mosaicMode;
      if (previous.shapeType == ShapeType.mosaic &&
          nextMode != previous.mosaicMode) {
        final restored = _mosaicModeColor[nextMode] ?? previous.color;
        newSettings = newSettings.copyWith(color: restored);
      }
      _mosaicModeColor[nextMode] = newSettings.color;
    }
    _toolColor[newSettings.shapeType] = newSettings.color;
    _settings = newSettings;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Selection
  // ---------------------------------------------------------------------------

  void selectAnnotation(int index) {
    if (index < 0 || index >= annotations.length) return;
    _selectedIndex = index;
    _syncSettingsFromSelection(annotations[index]);
    notifyListeners();
  }

  void deselectAnnotation() {
    if (_selectedIndex == null) return;
    _selectedIndex = null;
    notifyListeners();
  }

  void deleteSelected() {
    if (_selectedIndex == null) return;
    final idx = _selectedIndex!;
    _selectedIndex = null;
    // Commit a new history entry with the annotation removed.
    final updated = [...annotations]..removeAt(idx);
    _commitSnapshot(updated);
  }

  // ---------------------------------------------------------------------------
  // Edit lifecycle (for handle drags — single undo entry)
  // ---------------------------------------------------------------------------

  void beginEdit() {
    if (_selectedIndex == null) return;
    _editing = true;
    _preEditSnapshot = [...annotations];
  }

  void updateSelected(Annotation updated) {
    if (!_editing || _selectedIndex == null) return;
    // Replace in-place (no history push).
    final list = [...annotations];
    list[_selectedIndex!] = updated;
    _history[_historyIndex] = list;
    notifyListeners();
  }

  void commitEdit() {
    if (!_editing || _preEditSnapshot == null) return;
    _editing = false;
    final current = [...annotations];
    final before = _preEditSnapshot!;
    _history[_historyIndex] = before;
    _preEditSnapshot = null;
    // Skip history push if the selected annotation didn't actually change.
    final i = _selectedIndex;
    if (i != null &&
        i < current.length &&
        i < before.length &&
        current[i] == before[i]) {
      return;
    }
    _commitSnapshot(current);
  }

  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------

  void _commitSnapshot(List<Annotation> snapshot) {
    if (_historyIndex < _history.length - 1) {
      _history.removeRange(_historyIndex + 1, _history.length);
    }
    _history.add(snapshot);
    _historyIndex++;
    notifyListeners();
  }

  void _commitAnnotation(Annotation annotation) {
    _commitSnapshot([...annotations, annotation]);
  }

  void _syncSettingsFromSelection(Annotation annotation) {
    if (annotation.type != ShapeType.mosaic) return;

    _toolStrokeWidth[ShapeType.mosaic] = annotation.strokeWidth;
    _toolColor[ShapeType.mosaic] = annotation.color;
    _toolMosaicMode[ShapeType.mosaic] = annotation.mosaicMode;
    _mosaicModeColor[annotation.mosaicMode] = annotation.color;

    if (_settings.shapeType == ShapeType.mosaic) {
      _settings = _settings.copyWith(
        color: annotation.color,
        strokeWidth: annotation.strokeWidth,
        cornerRadius: annotation.cornerRadius,
        mosaicMode: annotation.mosaicMode,
      );
    }
  }

  bool applySettingsToSelected(DrawingSettings settings) {
    final idx = _selectedIndex;
    if (idx == null || idx >= annotations.length) return false;
    final selected = annotations[idx];
    if (selected.type != settings.shapeType) return false;
    final updated = _annotationWithSettings(selected, settings);
    if (updated == selected) return false;
    if (_editing) {
      updateSelected(updated);
    } else {
      beginEdit();
      updateSelected(updated);
      commitEdit();
    }
    return true;
  }

  Annotation _annotationWithSettings(
    Annotation annotation,
    DrawingSettings settings,
  ) {
    switch (annotation.type) {
      case ShapeType.rectangle:
        return annotation.copyWith(
          color: settings.color,
          strokeWidth: settings.strokeWidth,
          cornerRadius: settings.cornerRadius,
        );
      case ShapeType.ellipse:
      case ShapeType.arrow:
      case ShapeType.line:
      case ShapeType.pencil:
      case ShapeType.number:
        return annotation.copyWith(
          color: settings.color,
          strokeWidth: settings.strokeWidth,
        );
      case ShapeType.marker:
        return annotation.copyWith(
          color: settings.color,
          strokeWidth: settings.strokeWidth * 3,
        );
      case ShapeType.text:
        final updated = annotation.copyWith(
          color: settings.color,
          strokeWidth: settings.strokeWidth,
          fontFamily: settings.fontFamily,
        );
        final newEnd = _textBoundingEnd(updated, settings);
        return updated.copyWith(end: newEnd);
      case ShapeType.mosaic:
        return annotation.copyWith(
          color: settings.color,
          strokeWidth: settings.strokeWidth,
          cornerRadius: settings.cornerRadius,
          mosaicMode: settings.mosaicMode,
        );
    }
  }

  Offset _textBoundingEnd(Annotation annotation, DrawingSettings settings) {
    final text = annotation.text;
    if (text == null) return annotation.end;
    final textPainter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: settings.strokeWidth * 4,
          fontFamily: settings.fontFamily,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final end = Offset(
      annotation.start.dx + textPainter.width,
      annotation.start.dy + textPainter.height,
    );
    textPainter.dispose();
    return end;
  }

  /// Clear all annotations and reset history.
  void clear() {
    _history.clear();
    _history.add(const []);
    _historyIndex = 0;
    _activeAnnotation = null;
    _selectedIndex = null;
    _editing = false;
    _preEditSnapshot = null;
    _editingText = false;
    _textEditPosition = null;
    _toolStrokeWidth
      ..clear()
      ..[ShapeType.text] = 9.0
      ..[ShapeType.mosaic] = 8.0;
    _toolColor.clear();
    _toolMosaicMode.clear();
    _mosaicModeColor.clear();
    notifyListeners();
  }
}
