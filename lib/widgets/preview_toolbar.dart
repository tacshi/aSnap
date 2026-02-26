import 'package:flutter/material.dart';

/// Fixed action bar for the preview screen: Copy / Save / Discard.
///
/// Sits at the bottom of the preview window. Annotation tool buttons
/// live in the separate [FloatingToolbar].
class PreviewToolbar extends StatelessWidget {
  final VoidCallback onCopy;
  final VoidCallback onSave;
  final VoidCallback onDiscard;

  const PreviewToolbar({
    super.key,
    required this.onCopy,
    required this.onSave,
    required this.onDiscard,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xE6202020),
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ActionButton(
            icon: Icons.copy_rounded,
            label: 'Copy',
            onPressed: onCopy,
          ),
          const SizedBox(width: 4),
          _ActionButton(
            icon: Icons.save_alt_rounded,
            label: 'Save',
            onPressed: onSave,
          ),
          const SizedBox(width: 4),
          _ActionButton(
            icon: Icons.close_rounded,
            label: 'Discard',
            onPressed: onDiscard,
            isDestructive: true,
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool isDestructive;

  const _ActionButton({
    required this.icon,
    required this.label,
    this.onPressed,
    this.isDestructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = onPressed == null;
    final Color foreground;
    if (disabled) {
      foreground = Colors.white.withValues(alpha: 0.3);
    } else if (isDestructive) {
      foreground = Colors.red[300]!;
    } else {
      foreground = Colors.white;
    }

    return Tooltip(
      message: label,
      waitDuration: const Duration(milliseconds: 400),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          mouseCursor: disabled
              ? SystemMouseCursors.basic
              : SystemMouseCursors.click,
          borderRadius: BorderRadius.circular(22),
          hoverColor: disabled
              ? Colors.transparent
              : Colors.white.withValues(alpha: 0.1),
          child: Container(
            padding: const EdgeInsets.all(8),
            child: Icon(icon, color: foreground, size: 18),
          ),
        ),
      ),
    );
  }
}
