import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

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
  bool _focusRetryRunning = false;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _scheduleFocusSync() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _focusNode.hasFocus || _focusRetryRunning) return;
      _focusRetryRunning = true;
      _requestFocusWithRetry().whenComplete(() {
        _focusRetryRunning = false;
      });
    });
  }

  Future<void> _requestFocusWithRetry() async {
    for (var attempt = 0; attempt < 20; attempt++) {
      if (!mounted || _focusNode.hasFocus) return;
      await windowManager.focus();
      _focusNode.requestFocus();
      if (_focusNode.hasFocus) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.appState,
      builder: (context, _) {
        final image = widget.appState.capturedImage;
        if (image == null) {
          return const ColoredBox(color: Color(0xFF1E1E1E));
        }

        _scheduleFocusSync();
        return KeyboardListener(
          focusNode: _focusNode,
          autofocus: true,
          onKeyEvent: (event) {
            if (event is KeyDownEvent &&
                event.logicalKey == LogicalKeyboardKey.escape) {
              widget.onDiscard();
            }
          },
          child: DragToMoveArea(
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Screenshot fills the entire window (decoded ui.Image)
                RawImage(image: image, fit: BoxFit.contain),

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
          ),
        );
      },
    );
  }
}
