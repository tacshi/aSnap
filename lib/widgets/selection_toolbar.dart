import 'package:flutter/material.dart';

import '../models/annotation.dart';

/// Compact toolbar for the region selection overlay.
///
/// Displays individual annotation tool buttons (Rectangle, Ellipse, Arrow,
/// Line, Pencil, Marker), Undo/Redo, and action buttons (Copy, Save, Close)
/// in a dark pill-shaped container.
/// Positioned by the parent via [Positioned] in a [Stack].
class SelectionToolbar extends StatelessWidget {
  final VoidCallback onCopy;
  final VoidCallback onSave;
  final VoidCallback? onPin;
  final VoidCallback onClose;

  /// Called when a tool button is tapped. Null disables all tool buttons.
  final ValueChanged<ShapeType>? onToolTap;
  final VoidCallback? onUndo;
  final VoidCallback? onRedo;

  /// The currently active shape type, or null if no tool is active.
  final ShapeType? activeShapeType;
  final bool hasAnnotations;
  final bool canUndo;
  final bool canRedo;

  /// Layer link for anchoring the settings popover above the active tool.
  final LayerLink? settingsLayerLink;

  /// Global key for measuring the active tool position (popover clamping).
  final GlobalKey? settingsAnchorKey;

  const SelectionToolbar({
    super.key,
    required this.onCopy,
    required this.onSave,
    this.onPin,
    required this.onClose,
    this.onToolTap,
    this.onUndo,
    this.onRedo,
    this.activeShapeType,
    this.hasAnnotations = false,
    this.canUndo = false,
    this.canRedo = false,
    this.settingsLayerLink,
    this.settingsAnchorKey,
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
          // --- Annotation tool buttons (left side) ---
          if (onToolTap != null) ...[
            ..._buildToolButtons(),
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
          if (onPin != null) ...[
            const SizedBox(width: 4),
            _ActionButton(
              icon: Icons.push_pin_outlined,
              label: 'Pin',
              onPressed: onPin,
            ),
          ],
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

  List<Widget> _buildToolButtons() {
    const tools = [
      (ShapeType.rectangle, Icons.rectangle_outlined, 'Rectangle'),
      (ShapeType.ellipse, Icons.circle_outlined, 'Ellipse'),
      (ShapeType.arrow, Icons.arrow_right_alt_rounded, 'Arrow'),
      (ShapeType.line, Icons.horizontal_rule_rounded, 'Line'),
      (ShapeType.pencil, Icons.edit_outlined, 'Pencil'),
      (ShapeType.marker, Icons.brush_outlined, 'Marker'),
      (ShapeType.mosaic, Icons.blur_on_rounded, 'Mosaic'),
      (ShapeType.number, Icons.looks_one_outlined, 'Number'),
      (ShapeType.text, Icons.title_rounded, 'Text'),
    ];

    final widgets = <Widget>[];
    for (var i = 0; i < tools.length; i++) {
      if (i > 0) widgets.add(const SizedBox(width: 2));
      final (type, icon, label) = tools[i];
      final isActive = activeShapeType == type;
      Widget button = _ActionButton(
        icon: icon,
        label: label,
        onPressed: () => onToolTap!(type),
        isActive: isActive,
        customIcon: type == ShapeType.number ? const _CircledOneIcon() : null,
      );
      // Anchor the settings popover to the active tool button.
      if (isActive && settingsLayerLink != null) {
        button = CompositedTransformTarget(
          link: settingsLayerLink!,
          child: button,
        );
      }
      if (isActive && settingsAnchorKey != null) {
        button = KeyedSubtree(key: settingsAnchorKey, child: button);
      }
      widgets.add(button);
    }
    return widgets;
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool isDestructive;
  final bool isActive;

  /// Optional custom icon widget. When provided, takes priority over [icon].
  /// Receives the foreground color via [IconTheme].
  final Widget? customIcon;

  const _ActionButton({
    required this.icon,
    required this.label,
    this.onPressed,
    this.isDestructive = false,
    this.isActive = false,
    this.customIcon,
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
            decoration: isActive
                ? BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(22),
                  )
                : null,
            child: customIcon != null
                ? IconTheme(
                    data: IconThemeData(color: foreground, size: 18),
                    child: customIcon!,
                  )
                : Icon(icon, color: foreground, size: 18),
          ),
        ),
      ),
    );
  }
}

/// A circled "1" icon that reads color and size from [IconTheme].
class _CircledOneIcon extends StatelessWidget {
  const _CircledOneIcon();

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final color = theme.color ?? Colors.white;
    final size = theme.size ?? 18.0;
    return SizedBox(
      width: size,
      height: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: color, width: 1.5),
        ),
        child: Center(
          child: Text(
            '1',
            style: TextStyle(
              color: color,
              fontSize: size * 0.55,
              fontWeight: FontWeight.bold,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}
