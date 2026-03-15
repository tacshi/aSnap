import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

enum ShortcutAction { region, scrollCapture, fullScreen, pin, ocr }

extension ShortcutActionX on ShortcutAction {
  String get id => switch (this) {
    ShortcutAction.region => 'shortcut_region',
    ShortcutAction.scrollCapture => 'shortcut_scroll_capture',
    ShortcutAction.fullScreen => 'shortcut_full_screen',
    ShortcutAction.pin => 'shortcut_pin',
    ShortcutAction.ocr => 'shortcut_ocr',
  };

  String get label => switch (this) {
    ShortcutAction.region => 'Region',
    ShortcutAction.scrollCapture => 'Scroll',
    ShortcutAction.fullScreen => 'Full Screen',
    ShortcutAction.pin => 'Pin',
    ShortcutAction.ocr => 'OCR',
  };

  String get description => switch (this) {
    ShortcutAction.region => 'Start a region capture overlay.',
    ShortcutAction.scrollCapture => 'Start scroll capture mode.',
    ShortcutAction.fullScreen => 'Capture the display under the cursor.',
    ShortcutAction.pin => 'Pin the latest copied image to the screen.',
    ShortcutAction.ocr => 'Start an OCR region capture.',
  };
}

class ShortcutBindings {
  const ShortcutBindings({
    required this.region,
    required this.scrollCapture,
    required this.fullScreen,
    required this.pin,
    required this.ocr,
  });

  factory ShortcutBindings.defaults() {
    final primaryModifier = Platform.isMacOS
        ? HotKeyModifier.meta
        : HotKeyModifier.control;
    const secondaryModifier = HotKeyModifier.shift;

    return ShortcutBindings(
      region: defaultShortcutFor(
        ShortcutAction.region,
        key: PhysicalKeyboardKey.digit1,
        modifiers: [primaryModifier, secondaryModifier],
      ),
      scrollCapture: defaultShortcutFor(
        ShortcutAction.scrollCapture,
        key: PhysicalKeyboardKey.digit2,
        modifiers: [primaryModifier, secondaryModifier],
      ),
      fullScreen: defaultShortcutFor(
        ShortcutAction.fullScreen,
        key: PhysicalKeyboardKey.digit3,
        modifiers: [primaryModifier, secondaryModifier],
      ),
      pin: defaultShortcutFor(
        ShortcutAction.pin,
        key: PhysicalKeyboardKey.keyP,
        modifiers: [primaryModifier, secondaryModifier],
      ),
      ocr: defaultShortcutFor(
        ShortcutAction.ocr,
        key: PhysicalKeyboardKey.keyO,
        modifiers: [primaryModifier, secondaryModifier],
      ),
    );
  }

  factory ShortcutBindings.fromJson(Map<String, dynamic> json) {
    final defaults = ShortcutBindings.defaults();

    HotKey read(ShortcutAction action, HotKey fallback) {
      final raw = json[action.name];
      if (raw is! Map) return fallback;
      final map = Map<String, dynamic>.from(raw);
      try {
        return normalizeShortcutHotKey(action, HotKey.fromJson(map));
      } catch (_) {
        return fallback;
      }
    }

    return ShortcutBindings(
      region: read(ShortcutAction.region, defaults.region),
      scrollCapture: read(ShortcutAction.scrollCapture, defaults.scrollCapture),
      fullScreen: read(ShortcutAction.fullScreen, defaults.fullScreen),
      pin: read(ShortcutAction.pin, defaults.pin),
      ocr: read(ShortcutAction.ocr, defaults.ocr),
    );
  }

  final HotKey region;
  final HotKey scrollCapture;
  final HotKey fullScreen;
  final HotKey pin;
  final HotKey ocr;

  Iterable<MapEntry<ShortcutAction, HotKey>> get entries sync* {
    yield MapEntry(ShortcutAction.region, region);
    yield MapEntry(ShortcutAction.scrollCapture, scrollCapture);
    yield MapEntry(ShortcutAction.fullScreen, fullScreen);
    yield MapEntry(ShortcutAction.pin, pin);
    yield MapEntry(ShortcutAction.ocr, ocr);
  }

  HotKey forAction(ShortcutAction action) => switch (action) {
    ShortcutAction.region => region,
    ShortcutAction.scrollCapture => scrollCapture,
    ShortcutAction.fullScreen => fullScreen,
    ShortcutAction.pin => pin,
    ShortcutAction.ocr => ocr,
  };

  ShortcutBindings copyWithAction(ShortcutAction action, HotKey hotKey) {
    final normalized = normalizeShortcutHotKey(action, hotKey);
    return ShortcutBindings(
      region: action == ShortcutAction.region ? normalized : region,
      scrollCapture: action == ShortcutAction.scrollCapture
          ? normalized
          : scrollCapture,
      fullScreen: action == ShortcutAction.fullScreen ? normalized : fullScreen,
      pin: action == ShortcutAction.pin ? normalized : pin,
      ocr: action == ShortcutAction.ocr ? normalized : ocr,
    );
  }

  Map<String, dynamic> toJson() => {
    ShortcutAction.region.name: region.toJson(),
    ShortcutAction.scrollCapture.name: scrollCapture.toJson(),
    ShortcutAction.fullScreen.name: fullScreen.toJson(),
    ShortcutAction.pin.name: pin.toJson(),
    ShortcutAction.ocr.name: ocr.toJson(),
  };

  ShortcutValidationResult validate() {
    final errors = <ShortcutAction, String>{};

    for (final entry in entries) {
      if ((entry.value.modifiers ?? const <HotKeyModifier>[]).isEmpty) {
        errors[entry.key] = 'Use at least one modifier key.';
      }
    }

    final seen = <String, ShortcutAction>{};
    for (final entry in entries) {
      final signature = shortcutSignature(entry.value);
      final existing = seen[signature];
      if (existing == null) {
        seen[signature] = entry.key;
        continue;
      }
      errors[entry.key] =
          'This shortcut is already assigned to ${existing.label}.';
      errors[existing] ??=
          'This shortcut is already assigned to ${entry.key.label}.';
    }

    return ShortcutValidationResult(errors);
  }

  String encodeJson() => jsonEncode(toJson());
}

class ShortcutValidationResult {
  const ShortcutValidationResult(this.errors);

  final Map<ShortcutAction, String> errors;

  bool get isValid => errors.isEmpty;

  String? errorFor(ShortcutAction action) => errors[action];
}

HotKey defaultShortcutFor(
  ShortcutAction action, {
  required PhysicalKeyboardKey key,
  required List<HotKeyModifier> modifiers,
}) {
  return HotKey(
    identifier: action.id,
    key: key,
    modifiers: sortModifiers(modifiers),
    scope: HotKeyScope.system,
  );
}

HotKey normalizeShortcutHotKey(ShortcutAction action, HotKey hotKey) {
  final modifiers = sortModifiers(
    {...?hotKey.modifiers}.toList(growable: false),
  );
  return HotKey(
    identifier: action.id,
    key: hotKey.physicalKey,
    modifiers: modifiers,
    scope: HotKeyScope.system,
  );
}

bool isShortcutModifierKey(PhysicalKeyboardKey key) {
  return HotKeyModifier.values.any((modifier) {
    return modifier.physicalKeys.contains(key);
  });
}

List<HotKeyModifier> shortcutModifiersFromPressedKeys(
  Iterable<PhysicalKeyboardKey> pressedKeys,
) {
  final keys = pressedKeys.toSet();
  return sortModifiers(
    HotKeyModifier.values
        .where((modifier) {
          return modifier.physicalKeys.any(keys.contains);
        })
        .toList(growable: false),
  );
}

List<HotKeyModifier> sortModifiers(List<HotKeyModifier> modifiers) {
  const order = <HotKeyModifier, int>{
    HotKeyModifier.control: 0,
    HotKeyModifier.meta: 1,
    HotKeyModifier.alt: 2,
    HotKeyModifier.shift: 3,
    HotKeyModifier.fn: 4,
    HotKeyModifier.capsLock: 5,
  };

  final next = [...modifiers];
  next.sort((a, b) => (order[a] ?? 99).compareTo(order[b] ?? 99));
  return next;
}

String shortcutSignature(HotKey hotKey) {
  final modifierPart = sortModifiers(
    {...?hotKey.modifiers}.toList(growable: false),
  ).map((modifier) => modifier.name).join('+');
  return '${hotKey.physicalKey.usbHidUsage}:$modifierPart';
}

String shortcutDisplayLabel(HotKey hotKey) {
  if (Platform.isMacOS) {
    return _macOsShortcutDisplayParts(hotKey).join();
  }
  return shortcutDisplayParts(hotKey).join(' + ');
}

List<String> shortcutDisplayParts(HotKey hotKey) {
  return <String>[
    ...?hotKey.modifiers?.map(shortcutModifierLabel),
    shortcutKeyLabel(hotKey.physicalKey, hotKey.logicalKey),
  ];
}

List<String> _macOsShortcutDisplayParts(HotKey hotKey) {
  final modifiers = [...?hotKey.modifiers];
  modifiers.sort((a, b) {
    const order = <HotKeyModifier, int>{
      HotKeyModifier.control: 0,
      HotKeyModifier.alt: 1,
      HotKeyModifier.shift: 2,
      HotKeyModifier.meta: 3,
      HotKeyModifier.fn: 4,
      HotKeyModifier.capsLock: 5,
    };
    return (order[a] ?? 99).compareTo(order[b] ?? 99);
  });

  return <String>[
    ...modifiers.map(_macOsShortcutModifierLabel),
    _macOsShortcutKeyLabel(hotKey.physicalKey, hotKey.logicalKey),
  ];
}

List<Map<String, dynamic>> trayShortcutDescriptors(ShortcutBindings bindings) {
  final descriptors = <Map<String, dynamic>>[];

  for (final entry in bindings.entries) {
    final keyEquivalent = trayKeyEquivalent(entry.value);
    if (keyEquivalent == null) continue;
    descriptors.add({
      'label': entry.key.label,
      'keyEquivalent': keyEquivalent,
      'modifiers': [...?entry.value.modifiers?.map(_trayModifierName)],
    });
  }

  return descriptors;
}

String? trayKeyEquivalent(HotKey hotKey) {
  final label = hotKey.logicalKey.keyLabel;
  if (label.length == 1) {
    return label.toLowerCase();
  }

  return switch (hotKey.logicalKey) {
    LogicalKeyboardKey.space => ' ',
    _ => null,
  };
}

String shortcutModifierLabel(HotKeyModifier modifier) => switch (modifier) {
  HotKeyModifier.control => 'Ctrl',
  HotKeyModifier.meta => Platform.isMacOS ? 'Cmd' : 'Meta',
  HotKeyModifier.alt => Platform.isMacOS ? 'Option' : 'Alt',
  HotKeyModifier.shift => 'Shift',
  HotKeyModifier.fn => 'Fn',
  HotKeyModifier.capsLock => 'Caps Lock',
};

String _macOsShortcutModifierLabel(HotKeyModifier modifier) =>
    switch (modifier) {
      HotKeyModifier.control => '⌃',
      HotKeyModifier.alt => '⌥',
      HotKeyModifier.shift => '⇧',
      HotKeyModifier.meta => '⌘',
      HotKeyModifier.fn => 'fn',
      HotKeyModifier.capsLock => '⇪',
    };

String _trayModifierName(HotKeyModifier modifier) => switch (modifier) {
  HotKeyModifier.control => 'control',
  HotKeyModifier.meta => 'command',
  HotKeyModifier.alt => 'option',
  HotKeyModifier.shift => 'shift',
  HotKeyModifier.fn => 'function',
  HotKeyModifier.capsLock => 'capsLock',
};

String shortcutKeyLabel(
  PhysicalKeyboardKey physicalKey,
  LogicalKeyboardKey logicalKey,
) {
  final keyLabel = logicalKey.keyLabel.trim();
  if (keyLabel.isNotEmpty) {
    return keyLabel.length == 1 ? keyLabel.toUpperCase() : keyLabel;
  }

  final debugName = physicalKey.debugName ?? logicalKey.debugName ?? 'Key';
  return switch (debugName) {
    'Arrow Left' => 'Left',
    'Arrow Right' => 'Right',
    'Arrow Up' => 'Up',
    'Arrow Down' => 'Down',
    _ => debugName.replaceAll(' Digit', '').replaceAll(' Key', ''),
  };
}

String _macOsShortcutKeyLabel(
  PhysicalKeyboardKey physicalKey,
  LogicalKeyboardKey logicalKey,
) {
  final keyLabel = logicalKey.keyLabel.trim();
  if (keyLabel.isNotEmpty) {
    return keyLabel.length == 1 ? keyLabel.toUpperCase() : keyLabel;
  }

  return switch (logicalKey) {
    LogicalKeyboardKey.space => 'Space',
    LogicalKeyboardKey.enter => '↩',
    LogicalKeyboardKey.tab => '⇥',
    LogicalKeyboardKey.escape => '⎋',
    LogicalKeyboardKey.backspace => '⌫',
    LogicalKeyboardKey.arrowLeft => '←',
    LogicalKeyboardKey.arrowRight => '→',
    LogicalKeyboardKey.arrowUp => '↑',
    LogicalKeyboardKey.arrowDown => '↓',
    _ => shortcutKeyLabel(physicalKey, logicalKey),
  };
}
