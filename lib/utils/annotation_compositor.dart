import 'dart:ui' as ui;

import '../models/annotation.dart';
import '../widgets/annotation_painter.dart';

/// Flatten annotations onto a screenshot image, producing a new image.
///
/// Uses the same [PictureRecorder] + [Canvas] pattern as
/// [CaptureService.cropImage]. The source image is NOT disposed —
/// caller retains ownership. The returned image is owned by the caller.
Future<ui.Image> compositeAnnotations(
  ui.Image source,
  List<Annotation> annotations,
) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  final size = ui.Size(source.width.toDouble(), source.height.toDouble());

  // Pre-load pixel data for mosaic pixelation (compositor canvas is
  // untransformed so drawImageRect works, but sourcePixels provides
  // consistency with the overlay path).
  final sourcePixels = await source.toByteData(
    format: ui.ImageByteFormat.rawRgba,
  );

  // Draw the original image at full resolution.
  canvas.drawImage(source, ui.Offset.zero, ui.Paint());

  // Draw annotations at image resolution.
  final painter = AnnotationPainter(
    annotations: annotations,
    sourceImage: source,
    sourcePixels: sourcePixels,
  );
  painter.paint(canvas, size);

  final picture = recorder.endRecording();
  final result = await picture.toImage(source.width, source.height);
  picture.dispose();
  return result;
}
