import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:a_snap/widgets/selection_toolbar.dart';

void main() {
  group('SelectionToolbar', () {
    testWidgets('renders three action buttons', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SelectionToolbar(
                onCopy: () {},
                onSave: () {},
                onClose: () {},
              ),
            ),
          ),
        ),
      );

      expect(find.byIcon(Icons.copy_rounded), findsOneWidget);
      expect(find.byIcon(Icons.save_alt_rounded), findsOneWidget);
      expect(find.byIcon(Icons.close_rounded), findsOneWidget);
    });

    testWidgets('has tooltips for each button', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SelectionToolbar(
                onCopy: () {},
                onSave: () {},
                onClose: () {},
              ),
            ),
          ),
        ),
      );

      expect(find.byTooltip('Copy'), findsOneWidget);
      expect(find.byTooltip('Save'), findsOneWidget);
      expect(find.byTooltip('Close'), findsOneWidget);
    });

    testWidgets('onCopy callback fires when copy button tapped', (
      tester,
    ) async {
      var copied = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SelectionToolbar(
                onCopy: () => copied = true,
                onSave: () {},
                onClose: () {},
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
              child: SelectionToolbar(
                onCopy: () {},
                onSave: () => saved = true,
                onClose: () {},
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byIcon(Icons.save_alt_rounded));
      expect(saved, isTrue);
    });

    testWidgets('onClose callback fires when close button tapped', (
      tester,
    ) async {
      var closed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SelectionToolbar(
                onCopy: () {},
                onSave: () {},
                onClose: () => closed = true,
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byIcon(Icons.close_rounded));
      expect(closed, isTrue);
    });
  });
}
