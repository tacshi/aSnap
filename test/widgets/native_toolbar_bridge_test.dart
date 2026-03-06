import 'dart:ui' as ui;

import 'package:a_snap/models/annotation.dart';
import 'package:a_snap/screens/preview_screen.dart';
import 'package:a_snap/screens/region_selection_screen.dart';
import 'package:a_snap/screens/scroll_result_screen.dart';
import 'package:a_snap/services/window_service.dart';
import 'package:a_snap/state/annotation_state.dart';
import 'package:a_snap/state/app_state.dart';
import 'package:a_snap/widgets/shape_popover.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _ToolbarShowCall {
  final Rect rect;
  final bool showPin;
  final bool showHistoryControls;
  final bool canUndo;
  final bool canRedo;
  final String? activeTool;
  final bool anchorToWindow;

  const _ToolbarShowCall({
    required this.rect,
    required this.showPin,
    required this.showHistoryControls,
    required this.canUndo,
    required this.canRedo,
    required this.activeTool,
    required this.anchorToWindow,
  });
}

class _FakeWindowService extends WindowService {
  final List<_ToolbarShowCall> showCalls = [];
  int hideCalls = 0;

  @override
  Future<void> showToolbarPanel({
    required Rect rect,
    required bool showPin,
    required bool showHistoryControls,
    required bool canUndo,
    required bool canRedo,
    String? activeTool,
    bool anchorToWindow = false,
  }) async {
    showCalls.add(
      _ToolbarShowCall(
        rect: rect,
        showPin: showPin,
        showHistoryControls: showHistoryControls,
        canUndo: canUndo,
        canRedo: canRedo,
        activeTool: activeTool,
        anchorToWindow: anchorToWindow,
      ),
    );
  }

  @override
  Future<void> hideToolbarPanel() async {
    hideCalls++;
  }
}

class _RegionSelectionHarness extends StatefulWidget {
  final _FakeWindowService windowService;
  final AnnotationState annotationState;
  final ui.Image image;
  final VoidCallback onCancel;

  const _RegionSelectionHarness({
    required this.windowService,
    required this.annotationState,
    required this.image,
    required this.onCancel,
  });

  @override
  State<_RegionSelectionHarness> createState() => _RegionSelectionHarnessState();
}

class _RegionSelectionHarnessState extends State<_RegionSelectionHarness> {
  bool _visible = true;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: SizedBox.expand(
        child: _visible
            ? RegionSelectionScreen(
                decodedImage: widget.image,
                windowRects: const [],
                onCancel: () {
                  widget.onCancel();
                  setState(() => _visible = false);
                },
                windowService: widget.windowService,
                onCopy: (_) {},
                onSave: (_) {},
                annotationState: widget.annotationState,
              )
            : const SizedBox.shrink(),
      ),
    );
  }
}

const _windowManagerChannel = MethodChannel('window_manager');

Future<ui.Image> _createTestImage({int width = 240, int height = 160}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = const Color(0xFF4A90E2),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  picture.dispose();
  return image;
}

Future<void> _pumpTestApp(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(home: SizedBox.expand(child: child)));
  await tester.pump();
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_windowManagerChannel, (call) async {
          switch (call.method) {
            case 'focus':
              return true;
            case 'isFocused':
              return true;
            case 'getPosition':
              return {'dx': 0.0, 'dy': 0.0};
            case 'getSize':
              return {'width': 400.0, 'height': 300.0};
            default:
              return null;
          }
        });
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_windowManagerChannel, null);
  });

  group('PreviewScreen native toolbar bridge', () {
    testWidgets('dispatches actions and tool activation through window service', (
      tester,
    ) async {
      final image = await _createTestImage();
      final appState = AppState()..setCapturedImage(image);
      final annotationState = AnnotationState();
      final windowService = _FakeWindowService();
      var copied = 0;
      var saved = 0;
      var pinned = 0;
      var discarded = 0;

      addTearDown(() {
        appState.clear();
        annotationState.clear();
      });

      await _pumpTestApp(
        tester,
        PreviewScreen(
          appState: appState,
          annotationState: annotationState,
          windowService: windowService,
          onCopy: () => copied++,
          onSave: () => saved++,
          onPin: () => pinned++,
          onDiscard: () => discarded++,
        ),
      );

      expect(windowService.onToolbarAction, isNotNull);
      expect(windowService.showCalls, isNotEmpty);
      expect(windowService.showCalls.last.showPin, isTrue);
      expect(windowService.showCalls.last.showHistoryControls, isTrue);
      expect(windowService.showCalls.last.anchorToWindow, isTrue);

      windowService.onToolbarAction!.call('copy');
      windowService.onToolbarAction!.call('save');
      windowService.onToolbarAction!.call('pin');
      windowService.onToolbarAction!.call('close');

      expect(copied, 1);
      expect(saved, 1);
      expect(pinned, 1);
      expect(discarded, 1);

      windowService.onToolbarAction!.call('ellipse');
      await tester.pump();
      await tester.pump();

      expect(annotationState.settings.shapeType, ShapeType.ellipse);
      expect(find.byType(ShapePopover), findsOneWidget);
    });
  });

  group('RegionSelectionScreen native toolbar visibility', () {
    testWidgets('stays hidden until a selection exists and hides on cancel', (
      tester,
    ) async {
      final image = await _createTestImage(width: 300, height: 200);
      final annotationState = AnnotationState();
      final windowService = _FakeWindowService();
      var cancelCount = 0;

      addTearDown(annotationState.clear);
      addTearDown(image.dispose);

      await tester.pumpWidget(
        _RegionSelectionHarness(
          windowService: windowService,
          annotationState: annotationState,
          image: image,
          onCancel: () => cancelCount++,
        ),
      );
      await tester.pump();

      expect(windowService.showCalls, isEmpty);

      final gesture = await tester.startGesture(const Offset(20, 20));
      await gesture.moveTo(const Offset(160, 120));
      await gesture.up();
      await tester.pump();
      await tester.pump();

      expect(windowService.showCalls, isNotEmpty);
      expect(windowService.showCalls.last.showPin, isFalse);
      expect(windowService.showCalls.last.showHistoryControls, isTrue);

      windowService.onToolbarAction!.call('close');
      await tester.pump();
      await tester.pump();

      expect(cancelCount, 1);
      expect(windowService.hideCalls, greaterThan(0));
      expect(windowService.onToolbarAction, isNull);
    });
  });

  group('ScrollResultScreen native toolbar bridge', () {
    testWidgets('never requests pin and still routes tool actions', (
      tester,
    ) async {
      final image = await _createTestImage(width: 220, height: 420);
      final annotationState = AnnotationState();
      final windowService = _FakeWindowService();

      addTearDown(annotationState.clear);
      addTearDown(image.dispose);

      await _pumpTestApp(
        tester,
        ScrollResultScreen(
          stitchedImage: image,
          annotationState: annotationState,
          windowService: windowService,
          onCopy: () {},
          onSave: () {},
          onDiscard: () {},
        ),
      );

      expect(windowService.showCalls, isNotEmpty);
      expect(windowService.showCalls.last.showPin, isFalse);
      expect(windowService.showCalls.last.showHistoryControls, isTrue);

      windowService.onToolbarAction!.call('text');
      await tester.pump();
      await tester.pump();

      expect(annotationState.settings.shapeType, ShapeType.text);
      expect(find.byType(ShapePopover), findsOneWidget);
    });
  });
}
