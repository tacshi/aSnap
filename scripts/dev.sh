#!/bin/bash
set -e

echo "→ Formatting..."
dart format lib/

echo "→ Analyzing..."
flutter analyze

echo "→ Building macOS (debug)..."
flutter build macos --debug

echo "✓ Done"
