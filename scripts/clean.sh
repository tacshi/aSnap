#!/bin/bash
set -e

echo "→ Cleaning..."
flutter clean

echo "→ Getting dependencies..."
flutter pub get

echo "→ Building macOS (debug)..."
flutter build macos --debug

echo "✓ Done"
