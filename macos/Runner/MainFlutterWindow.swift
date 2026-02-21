import ApplicationServices
import Cocoa
import CoreGraphics
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var savedStyleMask: NSWindow.StyleMask?
  private var flutterChannel: FlutterMethodChannel?
  private var spaceChangeObserver: NSObjectProtocol?
  private var displayChangeMonitor: Any?
  /// The screen the overlay is currently displayed on (NS coordinates).
  private var overlayScreenFrame: NSRect?

  // Background rect polling
  private var rectPollingTimer: DispatchSourceTimer?
  private let rectPollingQueue = DispatchQueue(label: "com.asnap.rectPolling", qos: .utility)

  /// Append a debug line to ~/asnap_overlay.log
  private static func log(_ msg: String) {
    let line = "\(Date()) \(msg)\n"
    let path = NSHomeDirectory() + "/asnap_overlay.log"
    if let fh = FileHandle(forWritingAtPath: path) {
      fh.seekToEndOfFile()
      fh.write(line.data(using: .utf8)!)
      fh.closeFile()
    } else {
      FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
    }
  }

  override func awakeFromNib() {
    MainFlutterWindow.log("=== awakeFromNib: new code loaded ===")

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
    self.flutterChannel = channel
    channel.setMethodCallHandler { [weak self] (call, result) in
      MainFlutterWindow.log("channel call: \(call.method)")
      guard let self = self else {
        result(nil)
        return
      }
      switch call.method {
      case "captureScreen":
        // Capture either a single display (under cursor) or all connected
        // displays.  Pass {"allDisplays": true} for the multi-display composite
        // used by region selection; omit for single-display fullscreen capture.
        let allDisplays = (call.arguments as? [String: Any])?["allDisplays"] as? Bool ?? false
        let allScreens = NSScreen.screens
        guard !allScreens.isEmpty else { result(nil); return }

        let cgImage: CGImage?
        let logicalWidth: Double
        let logicalHeight: Double
        let cgOriginX: Double
        let cgOriginY: Double

        if allDisplays {
          // Union of all display bounds in CG coordinates (top-left origin)
          var dCount: UInt32 = 0
          CGGetActiveDisplayList(0, nil, &dCount)
          var dIDs = [CGDirectDisplayID](repeating: 0, count: Int(dCount))
          CGGetActiveDisplayList(dCount, &dIDs, &dCount)
          var unionCG = CGDisplayBounds(dIDs[0])
          for i in 1..<Int(dCount) { unionCG = unionCG.union(CGDisplayBounds(dIDs[i])) }

          cgImage = CGWindowListCreateImage(
            unionCG, .optionOnScreenOnly, kCGNullWindowID, .bestResolution
          )
          let nsUnion = allScreens.reduce(allScreens[0].frame) { $0.union($1.frame) }
          logicalWidth  = Double(nsUnion.size.width)
          logicalHeight = Double(nsUnion.size.height)
          cgOriginX = Double(unionCG.origin.x)
          cgOriginY = Double(unionCG.origin.y)
        } else {
          // Single display under the cursor
          let mouseLocation = NSEvent.mouseLocation
          let target = allScreens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main ?? allScreens[0]
          let displayID = (target.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
          MainFlutterWindow.log("captureScreen: mouse=\(mouseLocation) targetFrame=\(NSStringFromRect(target.frame)) displayID=\(displayID)")
          cgImage = CGDisplayCreateImage(displayID)
          logicalWidth  = Double(target.frame.size.width)
          logicalHeight = Double(target.frame.size.height)
          let primaryH = allScreens[0].frame.height
          cgOriginX = Double(target.frame.origin.x)
          cgOriginY = Double(primaryH - target.frame.maxY)
          MainFlutterWindow.log("  capture size=\(cgImage?.width ?? 0)x\(cgImage?.height ?? 0) logical=\(logicalWidth)x\(logicalHeight) cgOrigin=(\(cgOriginX),\(cgOriginY))")
        }

        guard let img = cgImage else { result(nil); return }
        let bitmapRep = NSBitmapImageRep(cgImage: img)
        guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
          result(nil); return
        }

        result([
          "bytes": FlutterStandardTypedData(bytes: pngData),
          "screenWidth": logicalWidth,
          "screenHeight": logicalHeight,
          "screenOriginX": cgOriginX,
          "screenOriginY": cgOriginY,
        ])
      case "enterOverlayMode":
        // Configure + position overlay at alpha=0.  Dart calls revealOverlay
        // after Flutter renders (which also installs monitors).
        self.configureOverlay(call.arguments as? [String: Double])
        result(nil)
      case "exitOverlayMode":
        // Remove space-change observer
        if let obs = self.spaceChangeObserver {
          NSWorkspace.shared.notificationCenter.removeObserver(obs)
          self.spaceChangeObserver = nil
        }
        // Remove display-change monitor
        if let monitor = self.displayChangeMonitor {
          NSEvent.removeMonitor(monitor)
          self.displayChangeMonitor = nil
        }
        self.overlayScreenFrame = nil
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
      case "suspendOverlay":
        // Make overlay invisible for display switching. Uses alphaValue instead
        // of orderOut so the window stays in the compositor and Flutter keeps
        // rendering to its backing store (no surface release/reacquire flash).
        if let monitor = self.displayChangeMonitor {
          NSEvent.removeMonitor(monitor)
          self.displayChangeMonitor = nil
        }
        if let obs = self.spaceChangeObserver {
          NSWorkspace.shared.notificationCenter.removeObserver(obs)
          self.spaceChangeObserver = nil
        }
        self.alphaValue = 0
        MainFlutterWindow.log("suspendOverlay: alpha=0")
        result(nil)
      case "repositionOverlay":
        // Move the invisible overlay to a new display (setFrame only).
        // Window stays alpha=0 so Flutter can render the new content at the
        // correct size before revealOverlay makes it visible.
        guard let args = call.arguments as? [String: Double] else {
          result(FlutterError(code: "INVALID_ARGS",
                              message: "repositionOverlay requires screenOriginX/Y",
                              details: nil))
          return
        }
        let allScreens = NSScreen.screens
        guard !allScreens.isEmpty else { result(nil); return }

        let targetCGX = args["screenOriginX"] ?? 0
        let targetCGY = args["screenOriginY"] ?? 0
        let primaryH = Double(allScreens[0].frame.height)
        let targetScreen = allScreens.first(where: { screen in
          let cgX = Double(screen.frame.origin.x)
          let cgY = primaryH - Double(screen.frame.maxY)
          return abs(cgX - targetCGX) < 2 && abs(cgY - targetCGY) < 2
        }) ?? allScreens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
          ?? NSScreen.main ?? allScreens[0]

        let screenFrame = targetScreen.frame
        self.overlayScreenFrame = screenFrame
        self.setFrame(screenFrame, display: true, animate: false)
        MainFlutterWindow.log("repositionOverlay: frame=\(NSStringFromRect(screenFrame))")
        result(nil)
      case "revealOverlay":
        // Make the overlay visible after Flutter has rendered the new content.
        self.alphaValue = 1
        self.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.installOverlayMonitors()
        MainFlutterWindow.log("revealOverlay: alpha=1")
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
        // Convert from Flutter top-left origin (relative to overlay) to macOS
        // bottom-left absolute coordinates. x/y are relative to the overlay
        // screen, so offset by the screen's NS origin.
        let screenFrame = self.overlayScreenFrame ?? NSScreen.main?.frame ?? .zero
        let macX = screenFrame.minX + x
        let macY = screenFrame.maxY - y - h
        self.overlayScreenFrame = nil
        self.level = .floating
        self.hasShadow = true
        self.collectionBehavior = []
        self.acceptsMouseMovedEvents = false
        // Clear constraints so the window can resize freely
        self.minSize = NSSize(width: 1, height: 1)
        self.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        self.setFrame(NSRect(x: macX, y: macY, width: w, height: h), display: true)
        // Re-activate so the window receives keyboard events (Esc to dismiss)
        self.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        result(nil)
      case "getWindowList":
        // Synchronous window list + AX tree walk. Shows permission prompt if needed.
        result(MainFlutterWindow.computeWindowRects(promptForAccess: true))
      case "startRectPolling":
        self.startRectPolling()
        result(nil)
      case "stopRectPolling":
        self.stopRectPolling()
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

  // Allow window to span multiple displays during overlay mode.
  // macOS constrains windows to a single screen by default; bypass that for the overlay.
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    if overlayScreenFrame != nil {
      MainFlutterWindow.log("constrainFrameRect BYPASSED: \(NSStringFromRect(frameRect))")
      return frameRect
    }
    let constrained = super.constrainFrameRect(frameRect, to: screen)
    if constrained != frameRect {
      MainFlutterWindow.log("constrainFrameRect CONSTRAINED: \(NSStringFromRect(frameRect)) -> \(NSStringFromRect(constrained))")
    }
    return constrained
  }

  // Suppress macOS system beep — key events are handled on the Flutter/Dart side
  override func keyDown(with event: NSEvent) {}

  // Hide window at launch — Dart side controls when to show via window_manager
  override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
    super.order(place, relativeTo: otherWin)
    hiddenWindowAtLaunch()
  }

  // MARK: - Background rect polling

  private func startRectPolling() {
    stopRectPolling()
    let timer = DispatchSource.makeTimerSource(queue: rectPollingQueue)
    // First poll fires immediately, then every 2 seconds.
    // If the AX walk takes ~1s, this leaves a ~1s idle gap between polls.
    timer.schedule(deadline: .now(), repeating: 2.0, leeway: .milliseconds(500))
    timer.setEventHandler { [weak self] in
      let rects = MainFlutterWindow.computeWindowRects(promptForAccess: false)
      DispatchQueue.main.async {
        self?.flutterChannel?.invokeMethod("onRectsUpdated", arguments: rects)
      }
    }
    timer.resume()
    rectPollingTimer = timer
    MainFlutterWindow.log("startRectPolling: started")
  }

  private func stopRectPolling() {
    if let timer = rectPollingTimer {
      timer.cancel()
      rectPollingTimer = nil
      MainFlutterWindow.log("stopRectPolling: stopped")
    }
  }

  // MARK: - Window rect computation

  /// Compute all visible window + AX sub-element rects. Thread-safe — callable from any queue.
  /// When [promptForAccess] is true, shows the Accessibility permission dialog if not trusted.
  /// When false (used by background polling), silently skips the AX walk if not trusted.
  private static func computeWindowRects(promptForAccess: Bool) -> [[String: Double]] {
    let ownPID = ProcessInfo.processInfo.processIdentifier
    let axTrusted: Bool
    if promptForAccess {
      axTrusted = AXIsProcessTrustedWithOptions(
        [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
      )
    } else {
      axTrusted = AXIsProcessTrusted()
    }

    guard let infoList = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements],
      kCGNullWindowID
    ) as? [[String: Any]] else { return [] }

    var rects: [[String: Double]] = []
    var walkedPIDs = Set<Int32>()

    for info in infoList {
      guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
      guard let pid = info[kCGWindowOwnerPID as String] as? Int32, pid != ownPID else { continue }
      guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary else { continue }
      guard let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
      if bounds.width < 10 || bounds.height < 10 { continue }
      if let alpha = info[kCGWindowAlpha as String] as? CGFloat, alpha < 0.01 { continue }

      rects.append([
        "x": Double(bounds.origin.x),
        "y": Double(bounds.origin.y),
        "width": Double(bounds.size.width),
        "height": Double(bounds.size.height),
      ])

      // Walk AX tree for sub-elements (once per app PID).
      // Depth 20 reaches deep into browser web content (e.g. individual tweets).
      // Cap total rects at 10 000 to bound latency on complex pages.
      if axTrusted && !walkedPIDs.contains(pid) {
        walkedPIDs.insert(pid)
        let appElement = AXUIElementCreateApplication(pid)
        var axWindows: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &axWindows) == .success,
           let windowArray = axWindows as? [AXUIElement] {
          for axWindow in windowArray {
            collectChildRects(
              element: axWindow,
              rects: &rects,
              depth: 0,
              maxDepth: 20,
              maxTotal: 10_000
            )
          }
        }
      }
    }
    return rects
  }

  // MARK: - Accessibility helpers

  /// Read the on-screen frame (position + size) of an AX element.
  /// Returns coordinates in CG points (top-left origin).
  private static func frameOfElement(_ element: AXUIElement) -> CGRect? {
    var posValue: CFTypeRef?
    var sizeValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue) == .success,
          AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success
    else { return nil }

    var point = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(posValue as! AXValue, .cgPoint, &point),
          AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
    else { return nil }

    return CGRect(origin: point, size: size)
  }

  /// Recursively walk AX children and collect their rects (≥10×10).
  /// Stops early when `rects.count` reaches `maxTotal` to bound latency.
  private static func collectChildRects(
    element: AXUIElement,
    rects: inout [[String: Double]],
    depth: Int,
    maxDepth: Int,
    maxTotal: Int
  ) {
    if depth >= maxDepth || rects.count >= maxTotal { return }

    var childrenValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
          let children = childrenValue as? [AXUIElement]
    else { return }

    for child in children {
      if rects.count >= maxTotal { return }
      if let frame = frameOfElement(child),
         frame.size.width >= 10, frame.size.height >= 10 {
        rects.append([
          "x": Double(frame.origin.x),
          "y": Double(frame.origin.y),
          "width": Double(frame.size.width),
          "height": Double(frame.size.height),
        ])
      }
      collectChildRects(element: child, rects: &rects, depth: depth + 1, maxDepth: maxDepth, maxTotal: maxTotal)
    }
  }

  // MARK: - Overlay helpers

  /// Find the target screen from arguments (CG origin) or mouse location,
  /// then configure + show the overlay window on that screen in one shot.
  /// Used for the initial ⌘⇧2 capture.
  private func configureOverlay(_ args: [String: Double]?) {
    let allScreens = NSScreen.screens
    guard !allScreens.isEmpty else { return }

    let targetScreen: NSScreen
    if let args = args,
       let targetCGX = args["screenOriginX"],
       let targetCGY = args["screenOriginY"] {
      let primaryH = Double(allScreens[0].frame.height)
      targetScreen = allScreens.first(where: { screen in
        let cgX = Double(screen.frame.origin.x)
        let cgY = primaryH - Double(screen.frame.maxY)
        return abs(cgX - targetCGX) < 2 && abs(cgY - targetCGY) < 2
      }) ?? allScreens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
        ?? NSScreen.main ?? allScreens[0]
      MainFlutterWindow.log("configureOverlay: matched by CG origin (\(targetCGX),\(targetCGY))")
    } else {
      let mouseLocation = NSEvent.mouseLocation
      targetScreen = allScreens.first(where: { $0.frame.contains(mouseLocation) })
        ?? NSScreen.main ?? allScreens[0]
      MainFlutterWindow.log("configureOverlay: matched by mouse \(mouseLocation)")
    }
    let screenFrame = targetScreen.frame
    MainFlutterWindow.log("configureOverlay: target=\(NSStringFromRect(screenFrame))")

    self.overlayScreenFrame = screenFrame

    if self.savedStyleMask == nil {
      self.savedStyleMask = self.styleMask
    }

    // Make window invisible but keep it in the compositor so Flutter keeps
    // rendering to its backing store. Dart calls revealOverlay after Flutter
    // has rendered the correct content (avoids black flash).
    self.alphaValue = 0
    self.styleMask = [.borderless]
    self.isOpaque = true
    self.backgroundColor = .black
    self.hasShadow = false
    self.isMovableByWindowBackground = false
    self.minSize = NSSize(width: 1, height: 1)
    self.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    self.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
    self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    self.ignoresMouseEvents = false
    self.acceptsMouseMovedEvents = true

    self.setFrame(screenFrame, display: true, animate: false)
    self.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    self.setFrame(screenFrame, display: true, animate: false)

    MainFlutterWindow.log("configureOverlay: done, frame=\(NSStringFromRect(self.frame))")
  }

  /// Install the Space-change and display-change monitors.
  /// Safe to call multiple times — cleans up old monitors first.
  private func installOverlayMonitors() {
    // Space-change observer
    if let obs = self.spaceChangeObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(obs)
    }
    self.spaceChangeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.activeSpaceDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.flutterChannel?.invokeMethod("onOverlayCancelled", arguments: nil)
    }

    // Display-change monitor (local, single-shot).
    if let oldMonitor = self.displayChangeMonitor {
      NSEvent.removeMonitor(oldMonitor)
    }
    self.displayChangeMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.mouseMoved, .leftMouseDragged]
    ) { [weak self] event in
      guard let self = self, let overlayFrame = self.overlayScreenFrame else { return event }
      let mouse = NSEvent.mouseLocation
      if !overlayFrame.contains(mouse) {
        if let monitor = self.displayChangeMonitor {
          NSEvent.removeMonitor(monitor)
          self.displayChangeMonitor = nil
        }
        MainFlutterWindow.log("displayChange: mouse=\(mouse) left overlay=\(NSStringFromRect(overlayFrame))")
        self.flutterChannel?.invokeMethod("onOverlayDisplayChanged", arguments: nil)
      }
      return event
    }
  }
}
