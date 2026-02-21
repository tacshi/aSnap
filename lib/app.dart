import 'package:flutter/material.dart';

import 'screens/preview_screen.dart';
import 'screens/region_selection_screen.dart';
import 'state/app_state.dart';

class ASnapApp extends StatelessWidget {
  final AppState appState;
  final VoidCallback onCopy;
  final VoidCallback onSave;
  final VoidCallback onDiscard;
  final void Function(Rect selectionRect) onRegionSelected;
  final VoidCallback onRegionCancel;

  const ASnapApp({
    super.key,
    required this.appState,
    required this.onCopy,
    required this.onSave,
    required this.onDiscard,
    required this.onRegionSelected,
    required this.onRegionCancel,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'aSnap',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: ListenableBuilder(
        listenable: appState,
        builder: (context, _) {
          if (appState.status == CaptureStatus.selecting &&
              appState.fullScreenBytes != null) {
            return RegionSelectionScreen(
              fullScreenBytes: appState.fullScreenBytes!,
              onCancel: onRegionCancel,
              onRegionSelected: onRegionSelected,
            );
          }
          return PreviewScreen(
            appState: appState,
            onCopy: onCopy,
            onSave: onSave,
            onDiscard: onDiscard,
          );
        },
      ),
    );
  }
}
