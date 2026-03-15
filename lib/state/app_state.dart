import 'dart:ui';

import 'package:flutter/foundation.dart';

enum CaptureKind { fullScreen, region, scroll, ocr }

enum SelectionMode { region, scroll, ocr }

enum CaptureStatus {
  idle,
  capturing,
  selecting,
  scrollSelecting,
  scrollCapturing,
  scrollResult,
  captured,
}

sealed class WorkflowState {
  const WorkflowState();
}

final class IdleWorkflow extends WorkflowState {
  const IdleWorkflow();
}

final class PreparingCaptureWorkflow extends WorkflowState {
  final CaptureKind kind;

  const PreparingCaptureWorkflow({required this.kind});
}

final class RegionSelectionWorkflow extends WorkflowState {
  final Image decodedImage;
  final List<Rect> windowRects;
  final Size screenSize;
  final Offset screenOrigin;
  final SelectionMode selectionMode;

  const RegionSelectionWorkflow({
    required this.decodedImage,
    required this.windowRects,
    required this.screenSize,
    required this.screenOrigin,
    required this.selectionMode,
  });

  RegionSelectionWorkflow copyWith({
    Image? decodedImage,
    List<Rect>? windowRects,
    Size? screenSize,
    Offset? screenOrigin,
    SelectionMode? selectionMode,
  }) {
    return RegionSelectionWorkflow(
      decodedImage: decodedImage ?? this.decodedImage,
      windowRects: windowRects ?? this.windowRects,
      screenSize: screenSize ?? this.screenSize,
      screenOrigin: screenOrigin ?? this.screenOrigin,
      selectionMode: selectionMode ?? this.selectionMode,
    );
  }

  bool get isScrollSelection => selectionMode == SelectionMode.scroll;
  bool get isOcrSelection => selectionMode == SelectionMode.ocr;
  bool get isQuickSelection => selectionMode != SelectionMode.region;
}

final class ScrollCapturingWorkflow extends WorkflowState {
  final Rect captureRegion;
  final int frameCount;
  final Image? previewImage;
  final Size screenSize;
  final Offset screenOrigin;

  const ScrollCapturingWorkflow({
    required this.captureRegion,
    required this.frameCount,
    required this.previewImage,
    required this.screenSize,
    required this.screenOrigin,
  });

  ScrollCapturingWorkflow copyWith({
    Rect? captureRegion,
    int? frameCount,
    Image? previewImage,
    bool clearPreviewImage = false,
    Size? screenSize,
    Offset? screenOrigin,
  }) {
    return ScrollCapturingWorkflow(
      captureRegion: captureRegion ?? this.captureRegion,
      frameCount: frameCount ?? this.frameCount,
      previewImage: clearPreviewImage
          ? null
          : (previewImage ?? this.previewImage),
      screenSize: screenSize ?? this.screenSize,
      screenOrigin: screenOrigin ?? this.screenOrigin,
    );
  }
}

final class PreviewWorkflow extends WorkflowState {
  final Image image;
  final bool isScrollCapture;

  const PreviewWorkflow({required this.image, required this.isScrollCapture});
}

final class ScrollResultWorkflow extends WorkflowState {
  final Image image;
  final Size screenSize;
  final Offset screenOrigin;

  const ScrollResultWorkflow({
    required this.image,
    required this.screenSize,
    required this.screenOrigin,
  });
}

final class SettingsWorkflow extends WorkflowState {
  const SettingsWorkflow();
}

class AppState extends ChangeNotifier {
  WorkflowState _workflow = const IdleWorkflow();
  WorkflowState get workflow => _workflow;

  Image? _detachedCapturedImage;
  Image? _detachedDecodedImage;

  RegionSelectionWorkflow? get regionSelectionWorkflow => switch (_workflow) {
    RegionSelectionWorkflow state => state,
    _ => null,
  };

  ScrollCapturingWorkflow? get scrollCapturingWorkflow => switch (_workflow) {
    ScrollCapturingWorkflow state => state,
    _ => null,
  };

  PreviewWorkflow? get previewWorkflow => switch (_workflow) {
    PreviewWorkflow state => state,
    _ => null,
  };

  ScrollResultWorkflow? get scrollResultWorkflow => switch (_workflow) {
    ScrollResultWorkflow state => state,
    _ => null,
  };

  Image? get decodedFullScreen => regionSelectionWorkflow?.decodedImage;

  Image? get capturedImage => switch (_workflow) {
    PreviewWorkflow(:final image) => image,
    ScrollResultWorkflow(:final image) => image,
    _ => null,
  };

  List<Rect>? get windowRects => regionSelectionWorkflow?.windowRects;

  Size? get screenSize => switch (_workflow) {
    RegionSelectionWorkflow(:final screenSize) => screenSize,
    ScrollCapturingWorkflow(:final screenSize) => screenSize,
    ScrollResultWorkflow(:final screenSize) => screenSize,
    _ => null,
  };

  Offset? get screenOrigin => switch (_workflow) {
    RegionSelectionWorkflow(:final screenOrigin) => screenOrigin,
    ScrollCapturingWorkflow(:final screenOrigin) => screenOrigin,
    ScrollResultWorkflow(:final screenOrigin) => screenOrigin,
    _ => null,
  };

  bool get isScrollCapture => switch (_workflow) {
    PreviewWorkflow(:final isScrollCapture) => isScrollCapture,
    ScrollResultWorkflow() => true,
    _ => false,
  };

  Rect? get scrollTargetBounds => scrollCapturingWorkflow?.captureRegion;

  int get scrollFrameCount => scrollCapturingWorkflow?.frameCount ?? 0;

  Image? get scrollPreviewImage => scrollCapturingWorkflow?.previewImage;

  CaptureStatus get status => switch (_workflow) {
    IdleWorkflow() => CaptureStatus.idle,
    SettingsWorkflow() => CaptureStatus.idle,
    PreparingCaptureWorkflow() => CaptureStatus.capturing,
    RegionSelectionWorkflow(selectionMode: SelectionMode.scroll) =>
      CaptureStatus.scrollSelecting,
    RegionSelectionWorkflow() => CaptureStatus.selecting,
    ScrollCapturingWorkflow() => CaptureStatus.scrollCapturing,
    ScrollResultWorkflow() => CaptureStatus.scrollResult,
    PreviewWorkflow() => CaptureStatus.captured,
  };

  void setPreparingCapture({required CaptureKind kind}) {
    _transitionTo(PreparingCaptureWorkflow(kind: kind));
  }

  void setScrollSelecting({
    required Image decodedImage,
    required List<Rect> windowRects,
    required Size screenSize,
    required Offset screenOrigin,
  }) {
    _transitionTo(
      RegionSelectionWorkflow(
        decodedImage: decodedImage,
        windowRects: windowRects,
        screenSize: screenSize,
        screenOrigin: screenOrigin,
        selectionMode: SelectionMode.scroll,
      ),
    );
  }

  void setOcrSelecting({
    required Image decodedImage,
    required List<Rect> windowRects,
    required Size screenSize,
    required Offset screenOrigin,
  }) {
    _transitionTo(
      RegionSelectionWorkflow(
        decodedImage: decodedImage,
        windowRects: windowRects,
        screenSize: screenSize,
        screenOrigin: screenOrigin,
        selectionMode: SelectionMode.ocr,
      ),
    );
  }

  void setScrollCapturing({required Rect captureRegion}) {
    final selection = regionSelectionWorkflow;
    if (selection == null) return;
    _transitionTo(
      ScrollCapturingWorkflow(
        captureRegion: captureRegion,
        frameCount: 0,
        previewImage: null,
        screenSize: selection.screenSize,
        screenOrigin: selection.screenOrigin,
      ),
    );
  }

  void updateScrollFrameCount(int count) {
    final scrollCapture = scrollCapturingWorkflow;
    if (scrollCapture == null) return;
    _transitionTo(scrollCapture.copyWith(frameCount: count));
  }

  /// Update the live scroll preview image (called by ScrollCaptureService).
  /// The image is owned by the service — we just hold a reference.
  /// Does NOT call notifyListeners() — the caller is responsible for
  /// triggering a rebuild (via updateScrollFrameCount) after setting this.
  void updateScrollPreview(Image newImage) {
    final scrollCapture = scrollCapturingWorkflow;
    if (scrollCapture == null) return;
    _workflow = scrollCapture.copyWith(previewImage: newImage);
  }

  void setSelecting({
    required Image decodedImage,
    required List<Rect> windowRects,
    required Size screenSize,
    required Offset screenOrigin,
  }) {
    _transitionTo(
      RegionSelectionWorkflow(
        decodedImage: decodedImage,
        windowRects: windowRects,
        screenSize: screenSize,
        screenOrigin: screenOrigin,
        selectionMode: SelectionMode.region,
      ),
    );
  }

  /// Update only the window rects (used when rects arrive after the overlay
  /// is already showing, e.g. during a display change).
  void updateWindowRects(List<Rect> rects) {
    final selection = regionSelectionWorkflow;
    if (selection == null) return;
    _transitionTo(selection.copyWith(windowRects: rects));
  }

  void setCapturedImage(Image image) {
    _transitionTo(PreviewWorkflow(image: image, isScrollCapture: false));
  }

  void setCapturedScrollImage(Image image) {
    _transitionTo(PreviewWorkflow(image: image, isScrollCapture: true));
  }

  void setSettings() {
    _transitionTo(const SettingsWorkflow());
  }

  /// Transition to scroll result displayed in the fullscreen overlay.
  void setScrollResult(Image stitchedImage) {
    final currentScreenSize = screenSize;
    final currentScreenOrigin = screenOrigin;
    if (currentScreenSize == null || currentScreenOrigin == null) {
      _transitionTo(
        PreviewWorkflow(image: stitchedImage, isScrollCapture: true),
      );
      return;
    }
    _transitionTo(
      ScrollResultWorkflow(
        image: stitchedImage,
        screenSize: currentScreenSize,
        screenOrigin: currentScreenOrigin,
      ),
    );
  }

  /// Encode the captured image to PNG bytes on demand (for clipboard/file save).
  Future<Uint8List?> capturedImageAsPng() async {
    final image = capturedImage;
    if (image == null) return null;
    final byteData = await image.toByteData(format: ImageByteFormat.png);
    return byteData?.buffer.asUint8List();
  }

  /// Remove and return the captured image without disposing it.
  /// Caller takes ownership and is responsible for disposal.
  Image? detachCapturedImage() {
    final image = capturedImage;
    if (image != null) {
      _detachedCapturedImage = image;
    }
    return image;
  }

  /// Remove and return the full-screen decoded image without disposing it.
  /// Caller takes ownership and is responsible for disposal.
  /// Used by overlay copy/save to detach before clear() disposes it.
  Image? detachDecodedFullScreen() {
    final image = decodedFullScreen;
    if (image != null) {
      _detachedDecodedImage = image;
    }
    return image;
  }

  /// Trigger a rebuild without changing any state.
  /// Used when the native window is shown/focused after initial state updates.
  void nudge() {
    notifyListeners();
  }

  void clear() {
    _transitionTo(const IdleWorkflow());
  }

  void _transitionTo(WorkflowState next) {
    final previous = _workflow;
    _disposeOwnedImages(previous, next);
    _workflow = next;
    _releaseDetachedImages(previous);
    notifyListeners();
  }

  void _disposeOwnedImages(WorkflowState previous, WorkflowState next) {
    for (final image in _ownedImages(previous)) {
      if (_ownsImage(next, image)) continue;
      if (identical(image, _detachedCapturedImage)) continue;
      if (identical(image, _detachedDecodedImage)) continue;
      image.dispose();
    }
  }

  Iterable<Image> _ownedImages(WorkflowState state) sync* {
    switch (state) {
      case RegionSelectionWorkflow(:final decodedImage):
        yield decodedImage;
      case PreviewWorkflow(:final image):
        yield image;
      case ScrollResultWorkflow(:final image):
        yield image;
      default:
        return;
    }
  }

  bool _ownsImage(WorkflowState state, Image image) {
    return _ownedImages(
      state,
    ).any((ownedImage) => identical(ownedImage, image));
  }

  void _releaseDetachedImages(WorkflowState previous) {
    switch (previous) {
      case RegionSelectionWorkflow(:final decodedImage):
        if (identical(decodedImage, _detachedDecodedImage)) {
          _detachedDecodedImage = null;
        }
      case PreviewWorkflow(:final image):
        if (identical(image, _detachedCapturedImage)) {
          _detachedCapturedImage = null;
        }
      case ScrollResultWorkflow(:final image):
        if (identical(image, _detachedCapturedImage)) {
          _detachedCapturedImage = null;
        }
      default:
        break;
    }
  }
}
