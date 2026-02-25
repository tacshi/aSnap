import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:a_snap/models/annotation.dart';
import 'package:a_snap/state/annotation_state.dart';
import 'package:a_snap/widgets/shape_popover.dart';

void main() {
  Widget wrapWithMaterial(Widget child) {
    return MaterialApp(
      home: Scaffold(body: Center(child: child)),
    );
  }

  group('ShapePopover mosaic color controls', () {
    testWidgets('hides color controls for pixelate mode', (tester) async {
      final state = AnnotationState();
      state.updateSettings(
        state.settings.copyWith(shapeType: ShapeType.mosaic),
      );
      state.updateSettings(
        state.settings.copyWith(mosaicMode: MosaicMode.pixelate),
      );

      await tester.pumpWidget(
        wrapWithMaterial(ShapePopover(annotationState: state, onDismiss: () {})),
      );

      expect(find.text('Color'), findsNothing);
    });

    testWidgets('hides color controls for blur mode', (tester) async {
      final state = AnnotationState();
      state.updateSettings(
        state.settings.copyWith(shapeType: ShapeType.mosaic),
      );
      state.updateSettings(
        state.settings.copyWith(mosaicMode: MosaicMode.blur),
      );

      await tester.pumpWidget(
        wrapWithMaterial(ShapePopover(annotationState: state, onDismiss: () {})),
      );

      expect(find.text('Color'), findsNothing);
    });

    testWidgets('shows color controls for solid color mode', (tester) async {
      final state = AnnotationState();
      state.updateSettings(
        state.settings.copyWith(shapeType: ShapeType.mosaic),
      );
      state.updateSettings(
        state.settings.copyWith(mosaicMode: MosaicMode.solidColor),
      );

      await tester.pumpWidget(
        wrapWithMaterial(ShapePopover(annotationState: state, onDismiss: () {})),
      );

      expect(find.text('Color'), findsOneWidget);
    });
  });
}
