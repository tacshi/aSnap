import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';

import '../models/annotation.dart';
import '../state/annotation_state.dart';

/// Floating popover for editing annotation settings (color, stroke, corner radius).
///
/// Shape selection is handled by the native toolbar panel; this popover
/// only exposes the style settings for the currently active tool.
/// Positioned by the caller (typically bottom-center of the preview window).
class ShapePopover extends StatelessWidget {
  final AnnotationState annotationState;
  final VoidCallback onDismiss;

  const ShapePopover({
    super.key,
    required this.annotationState,
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
    return TapRegion(
      onTapOutside: (_) => onDismiss(),
      child: ListenableBuilder(
        listenable: annotationState,
        builder: (context, _) {
          final settings = annotationState.settings;
          final showColorControls =
              settings.shapeType != ShapeType.mosaic ||
              settings.mosaicMode == MosaicMode.solidColor;
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
                    if (showColorControls) ...[
                      _buildColorRow(context, settings),
                      const SizedBox(height: 10),
                    ],
                    if (settings.shapeType == ShapeType.mosaic &&
                        settings.mosaicMode == MosaicMode.solidColor) ...[
                      _buildOpacitySlider(settings),
                      const SizedBox(height: 10),
                    ],
                    if (settings.shapeType != ShapeType.mosaic ||
                        settings.mosaicMode != MosaicMode.solidColor)
                      _buildStrokeSlider(settings),
                    if (settings.shapeType == ShapeType.rectangle ||
                        settings.shapeType == ShapeType.mosaic) ...[
                      const SizedBox(height: 10),
                      _buildCornerRadiusSlider(settings),
                    ],
                    if (settings.shapeType == ShapeType.mosaic) ...[
                      const SizedBox(height: 10),
                      _buildMosaicModePicker(settings),
                    ],
                    if (settings.shapeType == ShapeType.text) ...[
                      const SizedBox(height: 10),
                      _buildFontFamilyPicker(settings),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
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
    final isMosaic = settings.shapeType == ShapeType.mosaic;
    final isText = settings.shapeType == ShapeType.text;
    final label = isMosaic
        ? 'Intensity'
        : isText
        ? 'Size'
        : 'Stroke';
    final valueLabel = isMosaic
        ? '${settings.strokeWidth.round()}'
        : isText
        ? '${(settings.strokeWidth * 4).round()}px'
        : '${settings.strokeWidth.round()}px';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: const TextStyle(color: Colors.white70, fontSize: 11),
            ),
            Text(
              valueLabel,
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
              onChangeStart: (_) => annotationState.beginEdit(),
              onChanged: (value) {
                _applySettings(settings.copyWith(strokeWidth: value));
              },
              onChangeEnd: (_) => annotationState.commitEdit(),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildOpacitySlider(DrawingSettings settings) {
    final opacity = settings.color.a;
    final valueLabel = '${(opacity * 100).round()}%';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Opacity',
              style: TextStyle(color: Colors.white70, fontSize: 11),
            ),
            Text(
              valueLabel,
              style: const TextStyle(color: Colors.white54, fontSize: 11),
            ),
          ],
        ),
        SizedBox(
          height: 24,
          child: SliderTheme(
            data: _sliderTheme,
            child: Slider(
              value: opacity,
              min: 0.05,
              max: 1,
              divisions: 19,
              onChangeStart: (_) => annotationState.beginEdit(),
              onChanged: (value) {
                _applySettings(
                  settings.copyWith(
                    color: settings.color.withValues(alpha: value),
                  ),
                );
              },
              onChangeEnd: (_) => annotationState.commitEdit(),
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
              onChangeStart: (_) => annotationState.beginEdit(),
              onChanged: (value) {
                _applySettings(settings.copyWith(cornerRadius: value));
              },
              onChangeEnd: (_) => annotationState.commitEdit(),
            ),
          ),
        ),
      ],
    );
  }

  /// Font family options: display name → fontFamily value.
  static const _fontFamilies = <String, String?>{
    'Sans-serif': null,
    'Serif': 'Georgia',
    'Monospace': 'Courier New',
    'Handwriting': 'Comic Sans MS',
  };

  Widget _buildFontFamilyPicker(DrawingSettings settings) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Font',
          style: TextStyle(color: Colors.white70, fontSize: 11),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            for (final entry in _fontFamilies.entries)
              _FontChip(
                label: entry.key,
                fontFamily: entry.value,
                isSelected: settings.fontFamily == entry.value,
                onTap: () {
                  annotationState.beginEdit();
                  _applySettings(
                    settings.copyWith(
                      fontFamily: entry.value,
                      clearFontFamily: entry.value == null,
                    ),
                  );
                  annotationState.commitEdit();
                },
              ),
          ],
        ),
      ],
    );
  }

  /// Mosaic mode options: display name → MosaicMode value.
  static const _mosaicModes = <String, MosaicMode>{
    'Pixelate': MosaicMode.pixelate,
    'Blur': MosaicMode.blur,
    'Solid Color': MosaicMode.solidColor,
  };

  Widget _buildMosaicModePicker(DrawingSettings settings) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Mode',
          style: TextStyle(color: Colors.white70, fontSize: 11),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            for (final entry in _mosaicModes.entries)
              _ModeChip(
                label: entry.key,
                isSelected: settings.mosaicMode == entry.value,
                onTap: () {
                  annotationState.beginEdit();
                  _applySettings(settings.copyWith(mosaicMode: entry.value));
                  annotationState.commitEdit();
                },
              ),
          ],
        ),
      ],
    );
  }

  void _setColor(Color color) {
    annotationState.beginEdit();
    _applySettings(annotationState.settings.copyWith(color: color));
    annotationState.commitEdit();
  }

  void _applySettings(DrawingSettings settings) {
    annotationState.updateSettings(settings);
    if (annotationState.selectedIndex != null) {
      annotationState.applySettingsToSelected(annotationState.settings);
    }
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

// ---------------------------------------------------------------------------
// Font family chip
// ---------------------------------------------------------------------------

class _FontChip extends StatelessWidget {
  final String label;
  final String? fontFamily;
  final bool isSelected;
  final VoidCallback onTap;

  const _FontChip({
    required this.label,
    required this.fontFamily,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: isSelected
              ? Colors.white.withValues(alpha: 0.2)
              : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isSelected ? Colors.white54 : Colors.white24,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.white : Colors.white70,
            fontSize: 11,
            fontFamily: fontFamily,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Mosaic mode chip
// ---------------------------------------------------------------------------

class _ModeChip extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _ModeChip({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: isSelected
              ? Colors.white.withValues(alpha: 0.2)
              : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isSelected ? Colors.white54 : Colors.white24,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.white : Colors.white70,
            fontSize: 11,
          ),
        ),
      ),
    );
  }
}
