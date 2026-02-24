import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../models/annotation.dart';

/// Persisted drawing settings used when creating new annotations.
class DrawingSettings {
  final ShapeType shapeType;
  final Color color;
  final double strokeWidth;
  final double cornerRadius;

  const DrawingSettings({
    this.shapeType = ShapeType.rectangle,
    this.color = const Color(0xFFFF0000),
    this.strokeWidth = 6.0,
    this.cornerRadius = 20,
  });

  DrawingSettings copyWith({
    ShapeType? shapeType,
    Color? color,
    double? strokeWidth,
    double? cornerRadius,
  }) => DrawingSettings(
    shapeType: shapeType ?? this.shapeType,
    color: color ?? this.color,
    strokeWidth: strokeWidth ?? this.strokeWidth,
    cornerRadius: cornerRadius ?? this.cornerRadius,
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
  // Drawing lifecycle
  // ---------------------------------------------------------------------------

  void startDrawing(Offset startPoint) {
    _activeAnnotation = Annotation(
      type: _settings.shapeType,
      start: startPoint,
      end: startPoint,
      color: _settings.color,
      strokeWidth: _settings.strokeWidth,
      cornerRadius: _settings.cornerRadius,
    );
    notifyListeners();
  }

  void updateDrawing(Offset currentPoint, {bool constrained = false}) {
    if (_activeAnnotation == null) return;
    _activeAnnotation = _activeAnnotation!
        .withEnd(currentPoint)
        .withConstrained(constrained);
    notifyListeners();
  }

  void finishDrawing() {
    if (_activeAnnotation == null) return;
    final annotation = _activeAnnotation!;
    _activeAnnotation = null;

    // Only commit if the shape has meaningful size.
    final rect = Rect.fromPoints(annotation.start, annotation.end);
    if (rect.width.abs() < 2 && rect.height.abs() < 2) {
      notifyListeners();
      return;
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
    _settings = newSettings;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Selection
  // ---------------------------------------------------------------------------

  void selectAnnotation(int index) {
    if (index < 0 || index >= annotations.length) return;
    _selectedIndex = index;
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
    // Restore pre-edit state, then commit the current state as new entry.
    final current = [...annotations];
    _history[_historyIndex] = _preEditSnapshot!;
    _preEditSnapshot = null;
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

  /// Clear all annotations and reset history.
  void clear() {
    _history.clear();
    _history.add(const []);
    _historyIndex = 0;
    _activeAnnotation = null;
    _selectedIndex = null;
    _editing = false;
    _preEditSnapshot = null;
    notifyListeners();
  }
}
