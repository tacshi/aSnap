import 'package:flutter/material.dart';

/// Small floating badge (160x44) that shows scroll capture progress.
/// Displayed passively above the target window — the native window has
/// `ignoresMouseEvents = true` so this widget never steals focus.
class ScrollProgressBadge extends StatelessWidget {
  final int frameCount;
  final int maxFrames;
  final VoidCallback onCancel;

  const ScrollProgressBadge({
    super.key,
    required this.frameCount,
    required this.maxFrames,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.transparent,
      child: Center(
        child: Container(
          width: 160,
          height: 44,
          decoration: BoxDecoration(
            color: const Color(0xE0202020),
            borderRadius: BorderRadius.circular(10),
            boxShadow: const [
              BoxShadow(
                color: Color(0x40000000),
                blurRadius: 8,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(width: 12),
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white70,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                'Frame $frameCount / $maxFrames',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  decoration: TextDecoration.none,
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: onCancel,
                child: const Icon(Icons.close, size: 16, color: Colors.white54),
              ),
              const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );
  }
}
