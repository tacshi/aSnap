import 'package:flutter_test/flutter_test.dart';
import 'package:a_snap/state/annotation_state.dart';

void main() {
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
}
