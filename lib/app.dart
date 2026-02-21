import 'package:flutter/material.dart';

import 'screens/preview_screen.dart';
import 'state/app_state.dart';

class ASnapApp extends StatelessWidget {
  final AppState appState;
  final VoidCallback onCopy;
  final VoidCallback onSave;
  final VoidCallback onDiscard;

  const ASnapApp({
    super.key,
    required this.appState,
    required this.onCopy,
    required this.onSave,
    required this.onDiscard,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'aSnap',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: PreviewScreen(
        appState: appState,
        onCopy: onCopy,
        onSave: onSave,
        onDiscard: onDiscard,
      ),
    );
  }
}
