import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:a_snap/models/annotation.dart';
import 'package:a_snap/state/annotation_state.dart';

void main() {
  group('placeStamp', () {
    test('places first stamp with label 1', () {
      final state = AnnotationState();
      state.placeStamp(const Offset(50, 50));
      expect(state.annotations.length, 1);
      expect(state.annotations[0].type, ShapeType.number);
      expect(state.annotations[0].label, 1);
      expect(state.annotations[0].start, const Offset(50, 50));
    });

    test('auto-increments label', () {
      final state = AnnotationState();
      state.placeStamp(const Offset(50, 50));
      state.placeStamp(const Offset(100, 100));
      state.placeStamp(const Offset(150, 150));
      expect(state.annotations[0].label, 1);
      expect(state.annotations[1].label, 2);
      expect(state.annotations[2].label, 3);
    });

    test('undo removes stamp and next reuses number', () {
      final state = AnnotationState();
      state.placeStamp(const Offset(50, 50));
      state.placeStamp(const Offset(100, 100));
      state.placeStamp(const Offset(150, 150));
      expect(state.annotations.length, 3);

      state.undo(); // removes #3
      expect(state.annotations.length, 2);

      state.placeStamp(const Offset(200, 200));
      expect(state.annotations.last.label, 3); // reuses 3
    });

    test('delete leaves gaps — next uses highest + 1', () {
      final state = AnnotationState();
      state.placeStamp(const Offset(50, 50));
      state.placeStamp(const Offset(100, 100));
      state.placeStamp(const Offset(150, 150));

      // Delete #2 (label=2)
      state.selectAnnotation(1);
      state.deleteSelected();
      // Remaining: label 1, label 3
      expect(state.annotations.length, 2);

      state.placeStamp(const Offset(200, 200));
      expect(state.annotations.last.label, 4); // highest (3) + 1
    });

    test('stamp is auto-selected after placement', () {
      final state = AnnotationState();
      state.placeStamp(const Offset(50, 50));
      expect(state.selectedIndex, 0);
      state.placeStamp(const Offset(100, 100));
      expect(state.selectedIndex, 1);
    });

    test('stamp uses current settings color and strokeWidth', () {
      final state = AnnotationState();
      state.updateSettings(
        const DrawingSettings(color: Color(0xFF00FF00), strokeWidth: 8),
      );
      state.placeStamp(const Offset(50, 50));
      expect(state.annotations[0].color, const Color(0xFF00FF00));
      expect(state.annotations[0].strokeWidth, 8);
    });
  });

  group('selection', () {
    test('initially no selection', () {
      final state = AnnotationState();
      expect(state.selectedIndex, isNull);
      expect(state.selectedAnnotation, isNull);
    });

    test('selectAnnotation sets selectedIndex', () {
      final state = AnnotationState();
      state.startDrawing(Offset.zero);
      state.updateDrawing(const Offset(100, 100));
      state.finishDrawing();
      state.selectAnnotation(0);
      expect(state.selectedIndex, 0);
      expect(state.selectedAnnotation, isNotNull);
    });

    test('deselectAnnotation clears selection', () {
      final state = AnnotationState();
      state.startDrawing(Offset.zero);
      state.updateDrawing(const Offset(100, 100));
      state.finishDrawing();
      state.selectAnnotation(0);
      state.deselectAnnotation();
      expect(state.selectedIndex, isNull);
    });

    test('deleteSelected removes shape and clears selection', () {
      final state = AnnotationState();
      state.startDrawing(Offset.zero);
      state.updateDrawing(const Offset(100, 100));
      state.finishDrawing();
      expect(state.annotations.length, 1);
      state.selectAnnotation(0);
      state.deleteSelected();
      expect(state.annotations.length, 0);
      expect(state.selectedIndex, isNull);
    });

    test('deleteSelected supports undo', () {
      final state = AnnotationState();
      state.startDrawing(Offset.zero);
      state.updateDrawing(const Offset(100, 100));
      state.finishDrawing();
      state.selectAnnotation(0);
      state.deleteSelected();
      expect(state.annotations.length, 0);
      state.undo();
      expect(state.annotations.length, 1);
    });

    test('undo clears selection', () {
      final state = AnnotationState();
      state.startDrawing(Offset.zero);
      state.updateDrawing(const Offset(100, 100));
      state.finishDrawing();
      state.selectAnnotation(0);
      state.undo();
      expect(state.selectedIndex, isNull);
    });
  });

  group('beginEdit / commitEdit', () {
    test('single undo entry for entire drag gesture', () {
      final state = AnnotationState();
      state.startDrawing(Offset.zero);
      state.updateDrawing(const Offset(100, 100));
      state.finishDrawing();
      state.selectAnnotation(0);

      state.beginEdit();
      // Simulate multiple drag updates.
      state.updateSelected(
        state.selectedAnnotation!.withEnd(const Offset(110, 110)),
      );
      state.updateSelected(
        state.selectedAnnotation!.withEnd(const Offset(120, 120)),
      );
      state.updateSelected(
        state.selectedAnnotation!.withEnd(const Offset(130, 130)),
      );
      state.commitEdit();

      expect(state.annotations[0].end, const Offset(130, 130));
      // One undo should revert to original.
      state.undo();
      expect(state.annotations[0].end, const Offset(100, 100));
    });

    test('updateSelected without beginEdit is no-op', () {
      final state = AnnotationState();
      state.startDrawing(Offset.zero);
      state.updateDrawing(const Offset(100, 100));
      state.finishDrawing();
      state.selectAnnotation(0);
      // No beginEdit — updateSelected should be ignored
      state.updateSelected(
        state.selectedAnnotation!.withEnd(const Offset(200, 200)),
      );
      expect(state.annotations[0].end, const Offset(100, 100));
    });
  });

  group('finishDrawing auto-selects', () {
    test('new shape is auto-selected after drawing', () {
      final state = AnnotationState();
      state.startDrawing(Offset.zero);
      state.updateDrawing(const Offset(100, 100));
      state.finishDrawing();
      expect(state.selectedIndex, 0);
    });
  });

  group('text editing', () {
    test('startTextEdit enters editing mode', () {
      final state = AnnotationState();
      expect(state.editingText, isFalse);
      expect(state.textEditPosition, isNull);

      state.startTextEdit(const Offset(50, 50));
      expect(state.editingText, isTrue);
      expect(state.textEditPosition, const Offset(50, 50));
    });

    test('commitText creates text annotation', () {
      final state = AnnotationState();
      // Switch to text tool first (restores per-tool defaults).
      state.updateSettings(
        const DrawingSettings(shapeType: ShapeType.text, fontFamily: 'Georgia'),
      );
      // Per-tool default applies 9.0 strokeWidth (36px font) for text.
      expect(state.settings.strokeWidth, 9.0);
      // Then set the color (within the text tool).
      state.updateSettings(
        state.settings.copyWith(color: const Color(0xFF00FF00)),
      );

      state.startTextEdit(const Offset(10, 20));
      state.commitText('Hello', const Offset(80, 44));

      expect(state.editingText, isFalse);
      expect(state.textEditPosition, isNull);
      expect(state.annotations.length, 1);
      final a = state.annotations[0];
      expect(a.type, ShapeType.text);
      expect(a.text, 'Hello');
      expect(a.fontFamily, 'Georgia');
      expect(a.start, const Offset(10, 20));
      expect(a.end, const Offset(80, 44));
      expect(a.color, const Color(0xFF00FF00));
      expect(a.strokeWidth, 9.0);
    });

    test('commitText with empty text cancels', () {
      final state = AnnotationState();
      state.startTextEdit(const Offset(50, 50));
      state.commitText('   ', const Offset(100, 70));

      expect(state.editingText, isFalse);
      expect(state.annotations, isEmpty);
    });

    test('cancelTextEdit exits editing without commit', () {
      final state = AnnotationState();
      state.startTextEdit(const Offset(50, 50));
      state.cancelTextEdit();

      expect(state.editingText, isFalse);
      expect(state.textEditPosition, isNull);
      expect(state.annotations, isEmpty);
    });

    test('text annotation is auto-selected after commit', () {
      final state = AnnotationState();
      state.startTextEdit(const Offset(10, 10));
      state.commitText('Test', const Offset(60, 30));

      expect(state.selectedIndex, 0);
    });

    test('text annotation supports undo', () {
      final state = AnnotationState();
      state.startTextEdit(const Offset(10, 10));
      state.commitText('Test', const Offset(60, 30));
      expect(state.annotations.length, 1);

      state.undo();
      expect(state.annotations, isEmpty);

      state.redo();
      expect(state.annotations.length, 1);
      expect(state.annotations[0].text, 'Test');
    });

    test('clear resets text editing state', () {
      final state = AnnotationState();
      state.startTextEdit(const Offset(50, 50));
      state.clear();

      expect(state.editingText, isFalse);
      expect(state.textEditPosition, isNull);
    });
  });

  group('mosaic mode color', () {
    test('each mosaic mode keeps its own color', () {
      final state = AnnotationState();
      state.updateSettings(
        state.settings.copyWith(shapeType: ShapeType.mosaic),
      );

      // Pixelate color.
      state.updateSettings(
        state.settings.copyWith(color: const Color(0xFF00FF00)),
      );

      // Solid color mode with its own color.
      state.updateSettings(
        state.settings.copyWith(mosaicMode: MosaicMode.solidColor),
      );
      state.updateSettings(
        state.settings.copyWith(color: const Color(0xFF2979FF)),
      );

      // Switching back restores the pixelate color.
      state.updateSettings(
        state.settings.copyWith(mosaicMode: MosaicMode.pixelate),
      );
      expect(state.settings.color, const Color(0xFF00FF00));

      // Switching again restores the solid color.
      state.updateSettings(
        state.settings.copyWith(mosaicMode: MosaicMode.solidColor),
      );
      expect(state.settings.color, const Color(0xFF2979FF));
    });
  });

  group('tool color', () {
    test('each tool keeps its own color', () {
      final state = AnnotationState();
      // Rectangle (default tool) -> green.
      state.updateSettings(
        state.settings.copyWith(color: const Color(0xFF00FF00)),
      );

      // Switch to ellipse: should use default color, not rectangle's green.
      state.updateSettings(
        state.settings.copyWith(shapeType: ShapeType.ellipse),
      );
      expect(state.settings.color, const Color(0xFFFF0000));

      // Set ellipse to blue.
      state.updateSettings(
        state.settings.copyWith(color: const Color(0xFF2979FF)),
      );

      // Switch back to rectangle restores green.
      state.updateSettings(
        state.settings.copyWith(shapeType: ShapeType.rectangle),
      );
      expect(state.settings.color, const Color(0xFF00FF00));

      // Switch back to ellipse restores blue.
      state.updateSettings(
        state.settings.copyWith(shapeType: ShapeType.ellipse),
      );
      expect(state.settings.color, const Color(0xFF2979FF));
    });
  });

  group('applySettingsToSelected', () {
    test('keeps marker thickness scaling when updating selected marker', () {
      final state = AnnotationState();
      state.updateSettings(
        state.settings.copyWith(shapeType: ShapeType.marker, strokeWidth: 6),
      );
      state.startDrawing(const Offset(10, 10));
      state.updateDrawing(const Offset(100, 100));
      state.finishDrawing();
      expect(state.annotations.single.strokeWidth, 18.0);

      state.updateSettings(state.settings.copyWith(strokeWidth: 8));
      final applied = state.applySettingsToSelected(state.settings);

      expect(applied, isTrue);
      expect(state.annotations.single.strokeWidth, 24.0);
    });

    test('returns false when shape types do not match', () {
      final state = AnnotationState();
      // Draw a rectangle.
      state.startDrawing(const Offset(10, 10));
      state.updateDrawing(const Offset(100, 100));
      state.finishDrawing();
      expect(state.selectedIndex, 0);

      // Try to apply ellipse settings to the selected rectangle.
      final ellipseSettings = state.settings.copyWith(
        shapeType: ShapeType.ellipse,
      );
      expect(state.applySettingsToSelected(ellipseSettings), isFalse);
    });

    test('applies corner radius to selected rectangle', () {
      final state = AnnotationState();
      state.updateSettings(state.settings.copyWith(cornerRadius: 10));
      state.startDrawing(const Offset(10, 10));
      state.updateDrawing(const Offset(100, 100));
      state.finishDrawing();
      expect(state.annotations.single.cornerRadius, 10);

      state.updateSettings(state.settings.copyWith(cornerRadius: 30));
      final applied = state.applySettingsToSelected(state.settings);

      expect(applied, isTrue);
      expect(state.annotations.single.cornerRadius, 30);
    });

    test('applies mosaic mode to selected mosaic', () {
      final state = AnnotationState();
      state.updateSettings(
        state.settings.copyWith(shapeType: ShapeType.mosaic),
      );
      state.startDrawing(const Offset(10, 10));
      state.updateDrawing(const Offset(100, 100));
      state.finishDrawing();
      expect(state.annotations.single.mosaicMode, MosaicMode.pixelate);

      state.updateSettings(
        state.settings.copyWith(mosaicMode: MosaicMode.solidColor),
      );
      final applied = state.applySettingsToSelected(state.settings);

      expect(applied, isTrue);
      expect(state.annotations.single.mosaicMode, MosaicMode.solidColor);
    });

    test('returns false when no annotation is selected', () {
      final state = AnnotationState();
      state.startDrawing(const Offset(10, 10));
      state.updateDrawing(const Offset(100, 100));
      state.finishDrawing();
      state.deselectAnnotation();

      expect(state.applySettingsToSelected(state.settings), isFalse);
    });
  });

  group('syncSettingsFromSelection', () {
    test('syncs rectangle color and strokeWidth on selection', () {
      final state = AnnotationState();
      state.updateSettings(
        state.settings.copyWith(
          color: const Color(0xFF00FF00),
          strokeWidth: 10,
        ),
      );
      state.startDrawing(const Offset(10, 10));
      state.updateDrawing(const Offset(100, 100));
      state.finishDrawing();

      // Change settings away from the drawn annotation's values.
      state.updateSettings(
        state.settings.copyWith(color: const Color(0xFFFF0000), strokeWidth: 2),
      );

      // Select the annotation — settings should sync.
      state.selectAnnotation(0);
      expect(state.settings.color, const Color(0xFF00FF00));
      expect(state.settings.strokeWidth, 10);
    });

    test('syncs marker with reverse-scaled strokeWidth', () {
      final state = AnnotationState();
      // Switch to marker tool first, then set strokeWidth separately
      // (tool switch restores per-tool defaults, overriding the value).
      state.updateSettings(
        state.settings.copyWith(shapeType: ShapeType.marker),
      );
      state.updateSettings(state.settings.copyWith(strokeWidth: 5));
      state.startDrawing(const Offset(10, 10));
      state.updateDrawing(const Offset(100, 100));
      state.finishDrawing();
      // Marker stores 3× the UI value.
      expect(state.annotations.single.strokeWidth, 15.0);

      // Change settings away.
      state.updateSettings(state.settings.copyWith(strokeWidth: 2));

      // Select — should restore UI value (15 / 3 = 5).
      state.selectAnnotation(0);
      expect(state.settings.strokeWidth, 5);
    });
  });
}
