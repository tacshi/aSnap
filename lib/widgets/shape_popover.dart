import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';

import '../models/annotation.dart';
import '../state/annotation_state.dart';

/// Floating popover for editing annotation settings (color, stroke, corner radius).
///
/// Anchored to a [CompositedTransformTarget] via [layerLink]. Positioned
/// above the target with [Alignment.topCenter] → [Alignment.bottomCenter].
///
/// Shape selection is handled by individual toolbar buttons; this popover
/// only exposes the style settings for the currently active tool.
class ShapePopover extends StatelessWidget {
  final AnnotationState annotationState;
  final LayerLink layerLink;
  final VoidCallback onDismiss;

  const ShapePopover({
    super.key,
    required this.annotationState,
    required this.layerLink,
    required this.onDismiss,
  });

  static const _presetColors = [
    Color(0xFFFF0000), // Red
    Color(0xFF00C853), // Green
    Color(0xFF2979FF), // Blue
    Color(0xFFFFD600), // Yellow
    Color(0xFFFFFFFF), // White
    Color(0xFF000000), // Black
  ];

  @override
  Widget build(BuildContext context) {
    return CompositedTransformFollower(
      link: layerLink,
      targetAnchor: Alignment.topCenter,
      followerAnchor: Alignment.bottomCenter,
      offset: const Offset(0, -8),
      child: TapRegion(
        onTapOutside: (_) => onDismiss(),
        child: ListenableBuilder(
          listenable: annotationState,
          builder: (context, _) {
            final settings = annotationState.settings;
            return Material(
              type: MaterialType.transparency,
              child: Container(
                width: 220,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xE6202020),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.4),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: DefaultTextStyle(
                  style: const TextStyle(
                    decoration: TextDecoration.none,
                    color: Colors.white70,
                    fontSize: 11,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildColorRow(context, settings),
                      const SizedBox(height: 10),
                      _buildStrokeSlider(settings),
                      if (settings.shapeType == ShapeType.rectangle) ...[
                        const SizedBox(height: 10),
                        _buildCornerRadiusSlider(settings),
                      ],
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildColorRow(BuildContext context, DrawingSettings settings) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Color',
          style: TextStyle(color: Colors.white70, fontSize: 11),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            for (final color in _presetColors) ...[
              _ColorCircle(
                color: color,
                isSelected: settings.color == color,
                onTap: () => _setColor(color),
              ),
              const SizedBox(width: 6),
            ],
            _CustomColorButton(
              currentColor: settings.color,
              onColorPicked: _setColor,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildStrokeSlider(DrawingSettings settings) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Stroke',
              style: TextStyle(color: Colors.white70, fontSize: 11),
            ),
            Text(
              '${settings.strokeWidth.round()}px',
              style: const TextStyle(color: Colors.white54, fontSize: 11),
            ),
          ],
        ),
        SizedBox(
          height: 24,
          child: SliderTheme(
            data: _sliderTheme,
            child: Slider(
              value: settings.strokeWidth,
              min: 1,
              max: 20,
              divisions: 19,
              onChanged: (value) {
                annotationState.updateSettings(
                  settings.copyWith(strokeWidth: value),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCornerRadiusSlider(DrawingSettings settings) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Corner radius',
              style: TextStyle(color: Colors.white70, fontSize: 11),
            ),
            Text(
              '${settings.cornerRadius.round()}px',
              style: const TextStyle(color: Colors.white54, fontSize: 11),
            ),
          ],
        ),
        SizedBox(
          height: 24,
          child: SliderTheme(
            data: _sliderTheme,
            child: Slider(
              value: settings.cornerRadius,
              min: 0,
              max: 50,
              divisions: 50,
              onChanged: (value) {
                annotationState.updateSettings(
                  settings.copyWith(cornerRadius: value),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  void _setColor(Color color) {
    annotationState.updateSettings(
      annotationState.settings.copyWith(color: color),
    );
  }

  static final _sliderTheme = SliderThemeData(
    activeTrackColor: Colors.white70,
    inactiveTrackColor: Colors.white24,
    thumbColor: Colors.white,
    overlayColor: Colors.white.withValues(alpha: 0.1),
    trackHeight: 2,
    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
  );
}

// ---------------------------------------------------------------------------
// Color circle
// ---------------------------------------------------------------------------

class _ColorCircle extends StatelessWidget {
  final Color color;
  final bool isSelected;
  final VoidCallback onTap;

  const _ColorCircle({
    required this.color,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: isSelected ? Colors.white : Colors.white24,
            width: isSelected ? 2 : 1,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Custom color picker button
// ---------------------------------------------------------------------------

class _CustomColorButton extends StatelessWidget {
  final Color currentColor;
  final ValueChanged<Color> onColorPicked;

  const _CustomColorButton({
    required this.currentColor,
    required this.onColorPicked,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _showColorPicker(context),
      child: Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white24),
          gradient: const SweepGradient(
            colors: [
              Colors.red,
              Colors.orange,
              Colors.yellow,
              Colors.green,
              Colors.blue,
              Colors.purple,
              Colors.red,
            ],
          ),
        ),
        child: const Icon(Icons.add, color: Colors.white, size: 14),
      ),
    );
  }

  void _showColorPicker(BuildContext context) {
    var pickedColor = currentColor;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title: const Text(
          'Pick a color',
          style: TextStyle(color: Colors.white),
        ),
        content: SingleChildScrollView(
          child: ColorPicker(
            pickerColor: pickedColor,
            onColorChanged: (color) => pickedColor = color,
            enableAlpha: false,
            hexInputBar: true,
            labelTypes: const [],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              onColorPicked(pickedColor);
              Navigator.of(context).pop();
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
}
