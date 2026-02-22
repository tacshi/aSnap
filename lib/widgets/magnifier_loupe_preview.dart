import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import 'magnifier_loupe.dart';

/// Creates a simple 100x100 checkerboard image for preview purposes.
Future<ui.Image> _createCheckerboardImage() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  const size = 100.0;
  const cellSize = 10.0;

  for (var y = 0.0; y < size; y += cellSize) {
    for (var x = 0.0; x < size; x += cellSize) {
      final isEven = ((x + y) / cellSize).round() % 2 == 0;
      canvas.drawRect(
        Rect.fromLTWH(x, y, cellSize, cellSize),
        Paint()
          ..color = isEven ? const Color(0xFFCCCCCC) : const Color(0xFF666666),
      );
    }
  }

  final picture = recorder.endRecording();
  return picture.toImage(size.toInt(), size.toInt());
}

@Preview(name: 'MagnifierLoupe — center', size: Size(400, 300))
Widget magnifierLoupeCenter() {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      backgroundColor: const Color(0xFF2A2A2A),
      body: FutureBuilder<ui.Image>(
        future: _createCheckerboardImage(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          return Stack(
            children: [
              MagnifierLoupe(
                sourceImage: snapshot.data!,
                cursorPosition: const Offset(200, 150),
                devicePixelRatio: 2.0,
                screenSize: const Size(400, 300),
              ),
            ],
          );
        },
      ),
    ),
  );
}

@Preview(name: 'MagnifierLoupe — near edge', size: Size(400, 300))
Widget magnifierLoupeEdge() {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      backgroundColor: const Color(0xFF2A2A2A),
      body: FutureBuilder<ui.Image>(
        future: _createCheckerboardImage(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          return Stack(
            children: [
              MagnifierLoupe(
                sourceImage: snapshot.data!,
                cursorPosition: const Offset(380, 10),
                devicePixelRatio: 2.0,
                screenSize: const Size(400, 300),
              ),
            ],
          );
        },
      ),
    ),
  );
}
