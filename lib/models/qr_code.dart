import 'dart:ui';

class QrCodeResult {
  final Rect bounds;
  final String payload;

  const QrCodeResult({required this.bounds, required this.payload});

  static QrCodeResult? maybeParse(Map<dynamic, dynamic> map) {
    final payload = map['payload'] as String?;
    final x = map['x'] as num?;
    final y = map['y'] as num?;
    final width = map['width'] as num?;
    final height = map['height'] as num?;
    if (payload == null || payload.isEmpty) return null;
    if (x == null || y == null || width == null || height == null) return null;
    if (width <= 0 || height <= 0) return null;
    return QrCodeResult(
      bounds: Rect.fromLTWH(
        x.toDouble(),
        y.toDouble(),
        width.toDouble(),
        height.toDouble(),
      ),
      payload: payload,
    );
  }
}
