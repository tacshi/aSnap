<p align="center">
  <img src="assets/branding/aSnap.png" width="128" height="128" alt="aSnap icon">
</p>

<h1 align="center">aSnap</h1>

<p align="center">
  A fast, lightweight screenshot tool that lives in your menu bar.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS-blue" alt="macOS">
  <img src="https://img.shields.io/badge/platform-Windows-coming_soon-lightgrey" alt="Windows (coming soon)">
  <img src="https://img.shields.io/badge/built_with-Flutter-02569B" alt="Flutter">
</p>

## Features

### Capture Modes

| Mode | Hotkey | Description |
|------|--------|-------------|
| Region | ⌘⇧1 | Drag to select any area. Snaps to windows and UI elements via accessibility hit-testing. |
| Scroll | ⌘⇧2 | Auto-scroll and stitch long content into a single tall image. |
| Full Screen | ⌘⇧3 | Capture the entire display instantly. |
| Pin | ⌘⇧P | Pin a screenshot as a floating overlay on your screen. |

### Region Selection

- Freeform drag or auto-snap to windows and UI elements
- 8 resize handles to fine-tune the selection
- Drag to reposition the entire selection
- 10x magnifier loupe with pixel coordinates
- Right-click to go back, Escape to cancel

### Annotation Tools

Annotate directly on captured screenshots before copying or saving:

- **Shapes** — Rectangle (with corner radius), Ellipse, Arrow, Line
- **Freehand** — Pencil and semi-transparent Marker
- **Mosaic** — Pixelate, Blur, or Solid Color to redact sensitive content
- **Number Stamps** — Auto-incrementing numbered circles for callouts
- **Text** — Editable text with font and size selection

Each tool supports customizable color, stroke width, and Undo/Redo (⌘Z / ⌘⇧Z).

### Quick Actions

- **Copy** — PNG straight to your clipboard
- **Save** — Native save dialog with auto-generated filenames
- **Pin** — Float the screenshot above all windows
- **Discard** — Dismiss with Escape

## Installation

Download the latest release from [Releases](https://github.com/tacshi/aSnap/releases), or build from source:

```bash
git clone https://github.com/tacshi/aSnap.git
cd aSnap
flutter build macos --release
```

The built app is at `build/macos/Build/Products/Release/aSnap.app`. Drag it to your Applications folder.

### Permissions

aSnap requires **Screen Recording** and **Accessibility** permissions (System Settings → Privacy & Security). macOS will prompt you on first use.

## Development

```bash
# Dev cycle: format → analyze → build debug
./scripts/dev.sh

# Full clean rebuild
./scripts/clean.sh

# Run tests
flutter test
```

## License

MIT
