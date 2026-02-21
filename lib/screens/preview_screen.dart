import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../widgets/preview_toolbar.dart';

class PreviewScreen extends StatelessWidget {
  final AppState appState;
  final VoidCallback onCopy;
  final VoidCallback onSave;
  final VoidCallback onDiscard;

  const PreviewScreen({
    super.key,
    required this.appState,
    required this.onCopy,
    required this.onSave,
    required this.onDiscard,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final bytes = appState.screenshotBytes;
        if (bytes == null) {
          return const ColoredBox(color: Color(0xFF1E1E1E));
        }
        return Stack(
          fit: StackFit.expand,
          children: [
            // Screenshot fills the entire window
            Image.memory(bytes, fit: BoxFit.contain, gaplessPlayback: true),

            // Floating toolbar at bottom center
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Center(
                child: PreviewToolbar(
                  onCopy: onCopy,
                  onSave: onSave,
                  onDiscard: onDiscard,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
