import 'package:flutter/material.dart';

/// Compact toolbar for the region selection overlay.
///
/// Displays Copy, Save, and Close buttons in a dark pill-shaped container.
/// Positioned by the parent via [Positioned] in a [Stack].
class SelectionToolbar extends StatelessWidget {
  final VoidCallback onCopy;
  final VoidCallback onSave;
  final VoidCallback onClose;

  const SelectionToolbar({
    super.key,
    required this.onCopy,
    required this.onSave,
    required this.onClose,
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
            label: 'Close',
            onPressed: onClose,
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
  final VoidCallback onPressed;
  final bool isDestructive;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.isDestructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final foreground = isDestructive ? Colors.red[300]! : Colors.white;
    return Tooltip(
      message: label,
      waitDuration: const Duration(milliseconds: 400),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(22),
          hoverColor: Colors.white.withValues(alpha: 0.1),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(icon, color: foreground, size: 18),
          ),
        ),
      ),
    );
  }
}
