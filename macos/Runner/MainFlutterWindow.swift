import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var savedStyleMask: NSWindow.StyleMask?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Platform channel for overlay window control (above menu bar)
    let channel = FlutterMethodChannel(
      name: "com.asnap/window",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] (call, result) in
      guard let self = self else {
        result(nil)
        return
      }
      switch call.method {
      case "enterOverlayMode":
        guard let screen = NSScreen.main else {
          result(nil)
          return
        }
        // Save current style for restoration (only on first call)
        if self.savedStyleMask == nil {
          self.savedStyleMask = self.styleMask
        }

        // Borderless fullscreen window covering the entire screen (including menu bar)
        self.styleMask = [.borderless]
        self.isOpaque = true
        self.backgroundColor = .black
        self.hasShadow = false

        // Clear any window_manager size constraints so setFrame works freely
        self.minSize = NSSize(width: 1, height: 1)
        self.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        // Place window above the menu bar and everything else
        self.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.ignoresMouseEvents = false
        self.acceptsMouseMovedEvents = true

        self.setFrame(screen.frame, display: true)
        self.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        result(nil)
      case "exitOverlayMode":
        self.styleMask = self.savedStyleMask ?? [.titled, .closable, .miniaturizable, .resizable]
        self.savedStyleMask = nil
        self.isOpaque = true
        self.backgroundColor = .windowBackgroundColor
        self.hasShadow = true
        self.level = .normal
        self.collectionBehavior = []
        self.ignoresMouseEvents = false
        self.acceptsMouseMovedEvents = false
        result(nil)
      case "resizeToRect":
        // Shrink the borderless overlay window to the selection rect for in-place preview.
        // Stays borderless (no corner radius) and floating above other windows.
        guard let args = call.arguments as? [String: Double],
              let x = args["x"],
              let y = args["y"],
              let w = args["width"],
              let h = args["height"] else {
          result(FlutterError(code: "INVALID_ARGS",
                              message: "resizeToRect requires x, y, width, height",
                              details: nil))
          return
        }
        // Convert from Flutter top-left origin to macOS bottom-left origin
        let screenH = NSScreen.main?.frame.height ?? 0
        let macY = screenH - y - h
        self.level = .floating
        self.hasShadow = true
        self.collectionBehavior = []
        self.acceptsMouseMovedEvents = false
        // Clear constraints so the window can resize freely
        self.minSize = NSSize(width: 1, height: 1)
        self.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        self.setFrame(NSRect(x: x, y: macY, width: w, height: h), display: true)
        // Re-activate so the window receives keyboard events (Esc to dismiss)
        self.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }

  // Borderless windows return false by default — override so we receive keyboard events
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }

  // Hide window at launch — Dart side controls when to show via window_manager
  override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
    super.order(place, relativeTo: otherWin)
    hiddenWindowAtLaunch()
  }
}
