import 'package:flutter/material.dart';

/// Compact toolbar for the region selection overlay.
///
/// Displays annotation tools (Shapes, Undo, Redo) and action buttons
/// (Copy, Save, Close) in a dark pill-shaped container.
/// Positioned by the parent via [Positioned] in a [Stack].
class SelectionToolbar extends StatelessWidget {
  final VoidCallback onCopy;
  final VoidCallback onSave;
  final VoidCallback onClose;
  final VoidCallback? onShapesToggle;
  final VoidCallback? onUndo;
  final VoidCallback? onRedo;
  final bool shapesActive;
  final bool hasAnnotations;
  final bool canUndo;
  final bool canRedo;

  /// Layer link for anchoring the shape popover above the shapes button.
  final LayerLink? shapesLayerLink;

  const SelectionToolbar({
    super.key,
    required this.onCopy,
    required this.onSave,
    required this.onClose,
    this.onShapesToggle,
    this.onUndo,
    this.onRedo,
    this.shapesActive = false,
    this.hasAnnotations = false,
    this.canUndo = false,
    this.canRedo = false,
    this.shapesLayerLink,
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
          // --- Annotation tools (left side) ---
          if (onShapesToggle != null) ...[
            CompositedTransformTarget(
              link: shapesLayerLink ?? LayerLink(),
              child: _ActionButton(
                icon: Icons.edit_rounded,
                label: 'Shapes',
                onPressed: onShapesToggle!,
                isActive: shapesActive,
              ),
            ),
            if (hasAnnotations) ...[
              const SizedBox(width: 4),
              _ActionButton(
                icon: Icons.undo_rounded,
                label: 'Undo',
                onPressed: canUndo ? onUndo : null,
              ),
              const SizedBox(width: 4),
              _ActionButton(
                icon: Icons.redo_rounded,
                label: 'Redo',
                onPressed: canRedo ? onRedo : null,
              ),
            ],
            const SizedBox(width: 4),
            Container(
              width: 1,
              height: 18,
              color: Colors.white.withValues(alpha: 0.2),
            ),
            const SizedBox(width: 4),
          ],

          // --- Action buttons (right side) ---
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
  final VoidCallback? onPressed;
  final bool isDestructive;
  final bool isActive;

  const _ActionButton({
    required this.icon,
    required this.label,
    this.onPressed,
    this.isDestructive = false,
    this.isActive = false,
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
          borderRadius: BorderRadius.circular(22),
          hoverColor: disabled
              ? Colors.transparent
              : Colors.white.withValues(alpha: 0.1),
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: isActive
                ? BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(22),
                  )
                : null,
            child: Icon(icon, color: foreground, size: 18),
          ),
        ),
      ),
    );
  }
}
