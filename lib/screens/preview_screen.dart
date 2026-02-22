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
          child: widget.appState.isScrollCapture
              ? _buildScrollPreview(image)
              : _buildNormalPreview(image),
        );
      },
    );
  }

  Widget _buildNormalPreview(dynamic image) {
    return DragToMoveArea(
      child: Stack(
        fit: StackFit.expand,
        children: [
          RawImage(image: image, fit: BoxFit.contain),
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
  }

  Widget _buildScrollPreview(dynamic image) {
    // Scrollable layout for tall stitched images — no DragToMoveArea
    // (conflicts with scroll gesture).
    return Stack(
      children: [
        Positioned.fill(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final imageHeight =
                  constraints.maxWidth * (image.height / image.width);
              return SingleChildScrollView(
                child: SizedBox(
                  width: constraints.maxWidth,
                  height: imageHeight,
                  child: RawImage(image: image, fit: BoxFit.fitWidth),
                ),
              );
            },
          ),
        ),
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Colors.black54],
              ),
            ),
            child: Center(
              child: PreviewToolbar(
                onCopy: widget.onCopy,
                onSave: widget.onSave,
                onDiscard: widget.onDiscard,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
