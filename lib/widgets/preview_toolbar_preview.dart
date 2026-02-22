import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import 'preview_toolbar.dart';

@Preview(name: 'PreviewToolbar — dark background', size: Size(300, 80))
Widget previewToolbarDark() {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      backgroundColor: const Color(0xFF1A1A1A),
      body: Center(
        child: PreviewToolbar(onCopy: () {}, onSave: () {}, onDiscard: () {}),
      ),
    ),
  );
}

@Preview(name: 'PreviewToolbar — light background', size: Size(300, 80))
Widget previewToolbarLight() {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: PreviewToolbar(onCopy: () {}, onSave: () {}, onDiscard: () {}),
      ),
    ),
  );
}
