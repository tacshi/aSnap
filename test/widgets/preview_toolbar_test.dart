import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:a_snap/widgets/preview_toolbar.dart';

void main() {
  group('PreviewToolbar', () {
    testWidgets('renders three action buttons', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: PreviewToolbar(
                onCopy: () {},
                onSave: () {},
                onDiscard: () {},
              ),
            ),
          ),
        ),
      );

      // Three icon buttons: copy, save, discard
      expect(find.byIcon(Icons.copy_rounded), findsOneWidget);
      expect(find.byIcon(Icons.save_alt_rounded), findsOneWidget);
      expect(find.byIcon(Icons.close_rounded), findsOneWidget);
    });

    testWidgets('has tooltips for each button', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: PreviewToolbar(
                onCopy: () {},
                onSave: () {},
                onDiscard: () {},
              ),
            ),
          ),
        ),
      );

      expect(find.byTooltip('Copy'), findsOneWidget);
      expect(find.byTooltip('Save'), findsOneWidget);
      expect(find.byTooltip('Discard'), findsOneWidget);
    });

    testWidgets('onCopy callback fires when copy button tapped', (
      tester,
    ) async {
      var copied = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: PreviewToolbar(
                onCopy: () => copied = true,
                onSave: () {},
                onDiscard: () {},
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byIcon(Icons.copy_rounded));
      expect(copied, isTrue);
    });

    testWidgets('onSave callback fires when save button tapped', (
      tester,
    ) async {
      var saved = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: PreviewToolbar(
                onCopy: () {},
                onSave: () => saved = true,
                onDiscard: () {},
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byIcon(Icons.save_alt_rounded));
      expect(saved, isTrue);
    });

    testWidgets('onDiscard callback fires when discard button tapped', (
      tester,
    ) async {
      var discarded = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: PreviewToolbar(
                onCopy: () {},
                onSave: () {},
                onDiscard: () => discarded = true,
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byIcon(Icons.close_rounded));
      expect(discarded, isTrue);
    });
  });
}
