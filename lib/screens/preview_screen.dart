import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/app_state.dart';
import '../widgets/preview_toolbar.dart';

class PreviewScreen extends StatefulWidget {
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
  State<PreviewScreen> createState() => _PreviewScreenState();
}

class _PreviewScreenState extends State<PreviewScreen> {
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    // Ensure focus after window transitions (overlay → preview)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.appState,
      builder: (context, _) {
        final bytes = widget.appState.screenshotBytes;
        if (bytes == null) {
          return const ColoredBox(color: Color(0xFF1E1E1E));
        }
        return KeyboardListener(
          focusNode: _focusNode,
          autofocus: true,
          onKeyEvent: (event) {
            if (event is KeyDownEvent &&
                event.logicalKey == LogicalKeyboardKey.escape) {
              widget.onDiscard();
            }
          },
          child: Stack(
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
                    onCopy: widget.onCopy,
                    onSave: widget.onSave,
                    onDiscard: widget.onDiscard,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
