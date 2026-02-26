import ApplicationServices
import Cocoa
import CoreGraphics
import CoreText
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

  // Global Esc key monitor (catches Escape when our window isn't key)
  private var globalEscMonitor: Any?
  // Local Esc key monitor (catches Escape when our window is key but at alpha=0)
  private var localEscMonitor: Any?

  // Shortcut mapping for patching tray_manager's NSMenu with keyEquivalent.
  // Keys are menu item titles, values are (keyEquivalent, modifierMask).
  private var trayShortcuts: [String: (equiv: String, mask: NSEvent.ModifierFlags)] = [:]
  private var trayMenuObserver: NSObjectProtocol?

  // Tiny borderless panel placed over the Flutter "Done" button so it receives
  // mouse clicks even though the main overlay has ignoresMouseEvents = true.
  private var scrollStopPanel: NSPanel?

  // Floating toolbar panel (annotation tools + actions), separate from the
  // preview window so it can be dragged outside preview bounds.
  private var toolbarPanel: NSPanel?
  private var toolbarContentView: NSView?  // ToolbarContentView (macOS 11+)
  private var toolbarHitTestMonitor: Any?
  private var overlayIgnoresMouseForToolbar = false

  // Pinned image panel — floating sticker that persists across captures.
  private var pinnedPanel: PinnedImagePanel?

  private func screenAndBounds(forCGPoint point: CGPoint) -> (NSScreen, CGRect)? {
    for screen in NSScreen.screens {
      guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
        continue
      }
      let bounds = CGDisplayBounds(id.uint32Value)
      if bounds.contains(point) {
        return (screen, bounds)
      }
    }
    if let main = NSScreen.main,
       let id = main.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
      return (main, CGDisplayBounds(id.uint32Value))
    }
    return nil
  }

  /// Convert a CG-space rect (top-left origin) into an NS-space origin
  /// for positioning panels in global coordinates.
  private func nsOrigin(forCGTopLeftRect rect: CGRect) -> NSPoint {
    let cgPoint = rect.origin
    if let (screen, bounds) = screenAndBounds(forCGPoint: cgPoint) {
      let screenFrame = screen.frame
      let nsX = screenFrame.minX + (cgPoint.x - bounds.origin.x)
      let nsY = screenFrame.maxY - (cgPoint.y - bounds.origin.y) - rect.size.height
      return NSPoint(x: nsX, y: nsY)
    }
    let screenHeight = NSScreen.main?.frame.height ?? 0
    return NSPoint(x: rect.origin.x, y: screenHeight - rect.origin.y - rect.size.height)
  }

  /// Convert an NS-space rect (bottom-left origin) into a CG-space rect
  /// with a top-left origin in global display coordinates.
  private func cgTopLeftRect(forNSRect rect: NSRect, on screen: NSScreen?) -> CGRect? {
    guard let screen = screen ?? NSScreen.main else { return nil }
    guard let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else {
      let screenHeight = screen.frame.height
      return CGRect(
        x: rect.origin.x,
        y: screenHeight - rect.origin.y - rect.size.height,
        width: rect.size.width,
        height: rect.size.height
      )
    }
    let cgBounds = CGDisplayBounds(displayID)
    let screenFrame = screen.frame
    let cgX = cgBounds.origin.x + (rect.origin.x - screenFrame.minX)
    let cgY = cgBounds.origin.y + (screenFrame.maxY - rect.origin.y - rect.size.height)
    return CGRect(x: cgX, y: cgY, width: rect.size.width, height: rect.size.height)
  }

  /// Append a debug line to ~/asnap_overlay.log (debug builds only).
  private static func log(_ msg: String) {
    #if DEBUG
    let line = "\(Date()) \(msg)\n"
    guard let data = line.data(using: .utf8) else { return }
    let path = NSHomeDirectory() + "/asnap_overlay.log"
    if let fh = FileHandle(forWritingAtPath: path) {
      fh.seekToEndOfFile()
      fh.write(data)
      fh.closeFile()
    } else {
      FileManager.default.createFile(atPath: path, contents: data)
    }
    #endif
  }

  override func awakeFromNib() {
    MainFlutterWindow.log("=== awakeFromNib: new code loaded ===")

    // Enforce hidden launch state before any Dart-side window calls run.
    // This prevents the transient dark window flash on startup.
    self.alphaValue = 0
    // Keep window permanently non-opaque so Flutter's Metal pipeline is
    // configured with a transparent clear color from the very first frame.
    // Overlay/preview modes still look opaque because their Flutter widgets
    // paint every pixel — the transparent clear color is irrelevant there.
    // Scroll badge mode relies on this for true window transparency.
    self.isOpaque = false
    self.backgroundColor = .clear
    hiddenWindowAtLaunch()

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
          guard CGGetActiveDisplayList(0, nil, &dCount) == .success, dCount > 0 else {
            result(nil); return
          }
          var dIDs = [CGDirectDisplayID](repeating: 0, count: Int(dCount))
          guard CGGetActiveDisplayList(dCount, &dIDs, &dCount) == .success, dCount > 0 else {
            result(nil); return
          }
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
          guard let displayID = (target.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else {
            result(nil); return
          }
          MainFlutterWindow.log("captureScreen: mouse=\(mouseLocation) targetFrame=\(NSStringFromRect(target.frame)) displayID=\(displayID)")
          cgImage = CGDisplayCreateImage(displayID)
          logicalWidth  = Double(target.frame.size.width)
          logicalHeight = Double(target.frame.size.height)
          let cgBounds = CGDisplayBounds(displayID)
          cgOriginX = Double(cgBounds.origin.x)
          cgOriginY = Double(cgBounds.origin.y)
          MainFlutterWindow.log("  capture size=\(cgImage?.width ?? 0)x\(cgImage?.height ?? 0) logical=\(logicalWidth)x\(logicalHeight) cgOrigin=(\(cgOriginX),\(cgOriginY))")
        }

        guard let img = cgImage else { result(nil); return }

        // Force-convert to BGRA8888 via CGContext — CGWindowListCreateImage
        // doesn't guarantee a specific pixel format.  Dart side decodes with
        // PixelFormat.bgra8888 so the bytes must match exactly.
        let w = img.width
        let h = img.height
        let bpr = w * 4
        guard let ctx = CGContext(
            data: nil,
            width: w, height: h,
            bitsPerComponent: 8,
            bytesPerRow: bpr,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { result(nil); return }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let baseAddr = ctx.data else { result(nil); return }
        let pixelData = Data(bytes: baseAddr, count: h * bpr)

        result([
          "bytes": FlutterStandardTypedData(bytes: pixelData),
          "pixelWidth": w,
          "pixelHeight": h,
          "bytesPerRow": bpr,
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
      case "cleanupOverlayMode":
        // Overlay cleanup that also restores styleMask (needed so
        // window_manager's setTitleBarStyle won't crash on a borderless
        // window).  The alpha=0 guard inside cleanupOverlayState prevents
        // the hidden-window flash during the styleMask change.
        self.cleanupOverlayState(restoreStyleMask: true)
        result(nil)
      case "exitOverlayMode":
        self.cleanupOverlayState(restoreStyleMask: true)
        result(nil)
      case "setResizeCursor":
        // Set a diagonal resize cursor via private NSCursor API.
        // Flutter's SystemMouseCursors diagonal variants silently fall back
        // to the arrow cursor on macOS; calling the private API directly
        // from Swift works reliably.
        let args = call.arguments as? [String: Any]
        let type = args?["type"] as? String ?? ""
        self.setDiagonalResizeCursor(nwse: type == "nwse")
        result(nil)
      case "resetResizeCursor":
        // Clear the native diagonal resize cursor so Flutter can reclaim
        // cursor management (e.g., when the mouse leaves a corner handle).
        NSCursor.arrow.set()
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
        // Clear background so the compositor redraws the area behind the window.
        // isOpaque is already false (permanently) — see awakeFromNib comment.
        self.backgroundColor = .clear
        self.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
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
        let targetScreen = allScreens.first(where: { screen in
          guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return false
          }
          let bounds = CGDisplayBounds(id.uint32Value)
          return abs(Double(bounds.origin.x) - targetCGX) < 2 &&
            abs(Double(bounds.origin.y) - targetCGY) < 2
        }) ?? allScreens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
          ?? NSScreen.main ?? allScreens[0]

        let screenFrame = targetScreen.frame
        self.overlayScreenFrame = screenFrame
        self.setFrame(screenFrame, display: true, animate: false)
        MainFlutterWindow.log("repositionOverlay: frame=\(NSStringFromRect(screenFrame))")
        result(nil)
      case "revealOverlay":
        // Restore solid backing before making visible (reversed by suspendOverlay).
        // isOpaque stays false — see awakeFromNib comment.
        self.backgroundColor = .black
        self.contentView?.layer?.backgroundColor = NSColor.black.cgColor
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
        // Remove overlay monitors — selection is finished, transitioning to
        // in-place preview. Without this, a Space switch or mouse move could
        // fire stale overlay callbacks during preview.
        if let obs = self.spaceChangeObserver {
          NSWorkspace.shared.notificationCenter.removeObserver(obs)
          self.spaceChangeObserver = nil
        }
        if let monitor = self.displayChangeMonitor {
          NSEvent.removeMonitor(monitor)
          self.displayChangeMonitor = nil
        }
        self.overlayScreenFrame = nil
        self.level = .floating
        self.hasShadow = true
        self.collectionBehavior = [.moveToActiveSpace]
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
      case "checkAccessibility":
        // Check accessibility trust, optionally prompting the TCC dialog.
        let prompt = (call.arguments as? [String: Any])?["prompt"] as? Bool ?? false
        let trusted: Bool
        if prompt {
          trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
          )
        } else {
          trusted = AXIsProcessTrusted()
        }
        result(trusted)
      case "activateApp":
        self.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        result(nil)
      case "startEscMonitor":
        self.stopEscMonitorImpl()
        // Global monitor: catches Esc when our window is NOT key (capture setup phase)
        self.globalEscMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
          if event.keyCode == 53 { // Escape
            DispatchQueue.main.async {
              self?.flutterChannel?.invokeMethod("onEscPressed", arguments: nil)
            }
          }
        }
        // Local monitor: catches Esc when our window IS key but at alpha=0
        self.localEscMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
          if event.keyCode == 53 { // Escape
            DispatchQueue.main.async {
              self?.flutterChannel?.invokeMethod("onEscPressed", arguments: nil)
            }
            return nil // consume the event
          }
          return event
        }
        MainFlutterWindow.log("startEscMonitor: installed")
        result(nil)
      case "stopEscMonitor":
        self.stopEscMonitorImpl()
        MainFlutterWindow.log("stopEscMonitor: removed")
        result(nil)
      case "startRectPolling":
        self.startRectPolling()
        result(nil)
      case "stopRectPolling":
        self.stopRectPolling()
        result(nil)
      case "hitTestElement":
        // Real-time AX hit-test: find the deepest accessible element at
        // the given CG-coordinate position.
        //
        // AXUIElementCopyElementAtPosition may return an intermediate element
        // (e.g. a "WebArea" or "group") in complex apps like Electron/browsers.
        // To match Snipaste, we drill down through children to find the smallest
        // sub-element containing the point, and walk up the parent chain if the
        // initial element is too small.
        guard let args = call.arguments as? [String: Double],
              let cgX = args["x"], let cgY = args["y"] else {
          result(nil); return
        }
        let point = CGPoint(x: cgX, y: cgY)
        let ownPID = ProcessInfo.processInfo.processIdentifier

        // Find which app window sits at this position (skip our own).
        guard let infoList = CGWindowListCopyWindowInfo(
          [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { result(nil); return }

        var targetPID: Int32?
        for info in infoList {
          guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
          guard let pid = info[kCGWindowOwnerPID as String] as? Int32, pid != ownPID else { continue }
          guard let bd = info[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: bd) else { continue }
          if bounds.contains(point) {
            targetPID = pid
            break  // front-to-back order → first hit is the topmost
          }
        }
        guard let pid = targetPID, AXIsProcessTrusted() else { result(nil); return }

        let appElement = AXUIElementCreateApplication(pid)
        var axElement: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(appElement, Float(cgX), Float(cgY), &axElement)
        guard err == .success, let element = axElement else { result(nil); return }

        // Start with the returned element's frame.
        var bestFrame: CGRect? = nil
        var bestArea = Double.infinity
        if let frame = MainFlutterWindow.frameOfElement(element),
           frame.width >= 10, frame.height >= 10 {
          bestFrame = frame
          bestArea = Double(frame.width * frame.height)
        }

        // Drill down through children to find the smallest sub-element
        // that still contains the point. Only walks into children whose
        // frame contains the cursor, so it stays fast (typically 1-3
        // children per level).
        MainFlutterWindow.drillDownHitTest(
          element: element,
          point: point,
          bestFrame: &bestFrame,
          bestArea: &bestArea,
          depth: 0,
          maxDepth: 15
        )

        // If the initial element and its children were all < 10×10,
        // walk up the parent chain to find the nearest usable ancestor.
        if bestFrame == nil {
          var current: AXUIElement? = element
          while let el = current {
            var parentValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
              el, kAXParentAttribute as CFString, &parentValue
            ) == .success, CFGetTypeID(parentValue!) == AXUIElementGetTypeID() else { break }
            let parent = parentValue as! AXUIElement
            if let frame = MainFlutterWindow.frameOfElement(parent),
               frame.width >= 10, frame.height >= 10 {
              bestFrame = frame
              break
            }
            current = parent
          }
        }

        if let frame = bestFrame {
          result([
            "x": Double(frame.origin.x),
            "y": Double(frame.origin.y),
            "width": Double(frame.size.width),
            "height": Double(frame.size.height),
          ])
        } else {
          result(nil)
        }
      case "captureRegion":
        guard let args = call.arguments as? [String: Double],
              let x = args["x"],
              let y = args["y"],
              let w = args["width"],
              let h = args["height"] else {
          result(FlutterError(code: "INVALID_ARGS",
                              message: "captureRegion requires x, y, width, height",
                              details: nil))
          return
        }
        guard w > 0, h > 0 else {
          result(FlutterError(code: "INVALID_ARGS",
                              message: "captureRegion requires positive width and height",
                              details: nil))
          return
        }
        let cgRect = CGRect(x: x, y: y, width: w, height: h)
        // Capture all on-screen windows BELOW our overlay so the rainbow
        // border and preview panel don't contaminate scroll capture frames.
        // Our window is at .statusBar level, so all normal windows are below it.
        let ownWID = CGWindowID(self.windowNumber)
        let img = CGWindowListCreateImage(
          cgRect,
          [.optionOnScreenBelowWindow, .excludeDesktopElements],
          ownWID,
          .bestResolution
        )
        guard let img else { result(nil); return }

        let imgW = img.width
        let imgH = img.height
        let bpr = imgW * 4
        guard let ctx = CGContext(
          data: nil, width: imgW, height: imgH,
          bitsPerComponent: 8, bytesPerRow: bpr,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { result(nil); return }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: imgW, height: imgH))
        guard let baseAddr = ctx.data else { result(nil); return }
        let pixelData = Data(bytes: baseAddr, count: imgH * bpr)

        result([
          "bytes": FlutterStandardTypedData(bytes: pixelData),
          "pixelWidth": imgW,
          "pixelHeight": imgH,
          "bytesPerRow": bpr,
          "screenWidth": w,
          "screenHeight": h,
          "screenOriginX": x,
          "screenOriginY": y,
        ])
      case "enterScrollCaptureMode":
        // Transition from full-screen overlay to scroll capture mode.
        // Keep the window at full-screen size — Flutter widget handles rendering
        // the rainbow border and live preview panel. Only change interaction and
        // transparency properties.

        // Clean up overlay monitors (display-change only; reinstall space-change below).
        if let obs = self.spaceChangeObserver {
          NSWorkspace.shared.notificationCenter.removeObserver(obs)
          self.spaceChangeObserver = nil
        }
        if let monitor = self.displayChangeMonitor {
          NSEvent.removeMonitor(monitor)
          self.displayChangeMonitor = nil
        }
        self.overlayScreenFrame = nil

        // Re-install space-change observer for scroll capture mode.
        // Dart side dispatches based on current capture state.
        self.spaceChangeObserver = NSWorkspace.shared.notificationCenter.addObserver(
          forName: NSWorkspace.activeSpaceDidChangeNotification,
          object: nil,
          queue: .main
        ) { [weak self] _ in
          self?.flutterChannel?.invokeMethod("onOverlayCancelled", arguments: nil)
        }

        // Make overlay non-interactive so scroll events pass through to content.
        self.ignoresMouseEvents = true
        self.acceptsMouseMovedEvents = false

        // Transparent backgrounds for see-through overlay areas.
        self.backgroundColor = .clear
        self.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        self.setFlutterSurfaceOpaque(false)

        // Above normal windows but below system UI.
        self.level = .statusBar
        self.hasShadow = false

        // Delayed passes for lazily-created Metal layers.
        DispatchQueue.main.async { [weak self] in
          self?.setFlutterSurfaceOpaque(false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
          self?.setFlutterSurfaceOpaque(false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
          self?.setFlutterSurfaceOpaque(false)
        }
        MainFlutterWindow.log("enterScrollCaptureMode: frame=\(NSStringFromRect(self.frame))")
        result(nil)
      case "exitScrollCaptureMode":
        // Inverse of enterScrollCaptureMode: re-enable mouse interaction
        // while keeping the window fullscreen, borderless, and transparent.
        self.ignoresMouseEvents = false
        self.acceptsMouseMovedEvents = true
        self.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        MainFlutterWindow.log("exitScrollCaptureMode: frame=\(NSStringFromRect(self.frame))")
        result(nil)
      case "showScrollStopButton":
        guard let args = call.arguments as? [String: Double],
              let cgX = args["x"],
              let cgY = args["y"],
              let w = args["width"],
              let h = args["height"] else {
          result(nil); return
        }
        guard w > 0, h > 0 else {
          result(nil); return
        }

        // Convert CG coordinates (top-left origin) to NS coordinates (bottom-left).
        let cgRect = CGRect(x: cgX, y: cgY, width: w, height: h)
        let nsOrigin = self.nsOrigin(forCGTopLeftRect: cgRect)

        // Reuse existing panel or create a new one.
        let panel: NSPanel
        if let existing = self.scrollStopPanel {
          panel = existing
          panel.setFrame(NSRect(x: nsOrigin.x, y: nsOrigin.y, width: w, height: h), display: true)
        } else {
          panel = NSPanel(
            contentRect: NSRect(x: nsOrigin.x, y: nsOrigin.y, width: w, height: h),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
          )
          panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
          panel.backgroundColor = .clear
          panel.isOpaque = false
          panel.hasShadow = false
          panel.ignoresMouseEvents = false
          panel.collectionBehavior = [.canJoinAllSpaces, .stationary]

          // Transparent click-target view covering the entire panel.
          let clickView = ScrollStopClickView(frame: NSRect(x: 0, y: 0, width: w, height: h))
          clickView.autoresizingMask = [.width, .height]
          clickView.onClick = { [weak self] in
            self?.flutterChannel?.invokeMethod("onScrollCaptureDone", arguments: nil)
          }
          panel.contentView = clickView
          self.scrollStopPanel = panel
        }
        panel.orderFront(nil)
        result(nil)
      case "hideScrollStopButton":
        self.scrollStopPanel?.close()
        self.scrollStopPanel = nil
        result(nil)

      // MARK: Floating toolbar panel
      case "supportsToolbarPanel":
        if #available(macOS 11.0, *) {
          result(true)
        } else {
          result(false)
        }
      case "showToolbarPanel":
        guard #available(macOS 11.0, *) else { result(nil); return }
        guard let args = call.arguments as? [String: Double],
              let centerX = args["centerX"],
              let belowY = args["belowY"] else {
          result(nil); return
        }

        let panelWidth: CGFloat = 536
        let panelHeight: CGFloat = 44
        let cgRect = CGRect(
          x: centerX - panelWidth / 2,
          y: belowY,
          width: panelWidth,
          height: panelHeight
        )
        let nsOrigin = self.nsOrigin(forCGTopLeftRect: cgRect)
        let maxLevel = Int(CGWindowLevelForKey(.maximumWindow))
        let baseLevel = Int(self.level.rawValue)
        let desiredLevel = min(baseLevel + 1, maxLevel)
        let panelLevel = NSWindow.Level(rawValue: desiredLevel)
        let useAllSpaces = self.collectionBehavior.contains(.canJoinAllSpaces) ||
          self.collectionBehavior.contains(.fullScreenAuxiliary)
        let panelBehavior: NSWindow.CollectionBehavior = useAllSpaces
          ? [.canJoinAllSpaces, .fullScreenAuxiliary]
          : [.moveToActiveSpace]

        if let existing = self.toolbarPanel {
          existing.setFrame(
            NSRect(x: nsOrigin.x, y: nsOrigin.y, width: panelWidth, height: panelHeight),
            display: true
          )
          existing.level = panelLevel
          existing.collectionBehavior = panelBehavior
          existing.ignoresMouseEvents = false
          existing.becomesKeyOnlyIfNeeded = true
          existing.acceptsMouseMovedEvents = true
          existing.orderFront(nil)
        } else {
          let panel = NSPanel(
            contentRect: NSRect(
              x: nsOrigin.x,
              y: nsOrigin.y,
              width: panelWidth,
              height: panelHeight
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
          )
          panel.level = panelLevel
          panel.backgroundColor = .clear
          panel.isOpaque = false
          panel.hasShadow = true
          panel.isMovableByWindowBackground = true
          panel.collectionBehavior = panelBehavior
          panel.ignoresMouseEvents = false
          panel.becomesKeyOnlyIfNeeded = true
          panel.acceptsMouseMovedEvents = true

          let contentView = ToolbarContentView(
            frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
          )
          contentView.autoresizingMask = [.width, .height]
          contentView.onAction = { [weak self] action in
            DispatchQueue.main.async {
              self?.flutterChannel?.invokeMethod("onToolbarAction", arguments: action)
            }
          }
          panel.contentView = contentView
          self.toolbarPanel = panel
          self.toolbarContentView = contentView
          panel.orderFront(nil)
        }
        self.installToolbarHitTestMonitor()
        self.updateToolbarHitTesting()
        result(nil)

      case "hideToolbarPanel":
        self.toolbarPanel?.close()
        self.toolbarPanel = nil
        self.toolbarContentView = nil
        self.removeToolbarHitTestMonitor()
        result(nil)

      case "updateToolbarState":
        guard #available(macOS 11.0, *) else { result(nil); return }
        guard let args = call.arguments as? [String: Any] else {
          result(nil); return
        }
        let activeTool = args["activeTool"] as? String
        let canUndo = args["canUndo"] as? Bool ?? false
        let canRedo = args["canRedo"] as? Bool ?? false
        let hasAnnotations = args["hasAnnotations"] as? Bool ?? false
        let showsPin = args["showsPin"] as? Bool ?? true
        (self.toolbarContentView as? ToolbarContentView)?.updateState(
          activeTool: activeTool,
          canUndo: canUndo,
          canRedo: canRedo,
          hasAnnotations: hasAnnotations,
          showsPin: showsPin
        )
        result(nil)

      // MARK: Pinned image panel
      case "pinImage":
        guard let args = call.arguments as? [String: Any],
              let typedData = args["bytes"] as? FlutterStandardTypedData,
              let width = args["width"] as? Int,
              let height = args["height"] as? Int else {
          MainFlutterWindow.log("pinImage: INVALID ARGS — missing bytes/width/height")
          result(nil); return
        }
        let bytes = typedData.data
        MainFlutterWindow.log("pinImage: \(width)x\(height), bytes=\(bytes.count)")
        guard width > 0, height > 0, bytes.count >= width * height * 4 else {
          MainFlutterWindow.log("pinImage: INVALID size or bytes too short")
          result(nil); return
        }

        // Close any existing pin panel first.
        self.pinnedPanel?.close()
        self.pinnedPanel = nil

        // Create NSImage from raw RGBA bytes.
        guard let bitmapRep = NSBitmapImageRep(
          bitmapDataPlanes: nil,
          pixelsWide: width,
          pixelsHigh: height,
          bitsPerSample: 8,
          samplesPerPixel: 4,
          hasAlpha: true,
          isPlanar: false,
          colorSpaceName: .deviceRGB,
          bytesPerRow: width * 4,
          bitsPerPixel: 32
        ) else { result(nil); return }
        bytes.withUnsafeBytes { rawPtr in
          guard let src = rawPtr.baseAddress else { return }
          memcpy(bitmapRep.bitmapData!, src, width * height * 4)
        }
        let nsImage = NSImage(size: NSSize(width: width, height: height))
        nsImage.addRepresentation(bitmapRep)

        // Determine panel frame: use explicit CG frame if provided, else
        // fall back to the current main window frame.
        let panelFrame: NSRect
        if let fx = args["frameX"] as? Double,
           let fy = args["frameY"] as? Double,
           let fw = args["frameWidth"] as? Double,
           let fh = args["frameHeight"] as? Double {
          // CG coordinates (top-left origin) → NS coordinates (bottom-left origin).
          let cgRect = CGRect(x: fx, y: fy, width: fw, height: fh)
          let nsOrig = self.nsOrigin(forCGTopLeftRect: cgRect)
          panelFrame = NSRect(origin: nsOrig, size: cgRect.size)
        } else {
          panelFrame = self.frame
        }
        let panel = PinnedImagePanel(
          contentRect: panelFrame,
          styleMask: [.borderless, .nonactivatingPanel],
          backing: .buffered,
          defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.moveToActiveSpace]

        let imageView = PinnedImageView(frame: NSRect(origin: .zero, size: panelFrame.size))
        imageView.autoresizingMask = [.width, .height]
        imageView.displayImage = nsImage
        panel.contentView = imageView

        // Wire keyboard callbacks.
        panel.onEdit = { [weak self] in
          DispatchQueue.main.async {
            self?.flutterChannel?.invokeMethod("onEditPinnedImage", arguments: nil)
          }
        }
        panel.onClose = { [weak self] in
          DispatchQueue.main.async {
            self?.pinnedPanel = nil
            self?.flutterChannel?.invokeMethod("onPinnedImageClosed", arguments: nil)
          }
        }

        self.pinnedPanel = panel
        panel.makeKeyAndOrderFront(nil)
        MainFlutterWindow.log("pinImage: panel created at \(NSStringFromRect(panelFrame))")
        result(nil)

      case "closePinnedImage":
        self.pinnedPanel?.close()
        self.pinnedPanel = nil
        result(nil)

      case "getPinnedPanelFrame":
        guard let panel = self.pinnedPanel else { result(nil); return }
        // Convert NS frame (bottom-left origin) to CG frame (top-left origin)
        // in global display coordinates.
        let nsFrame = panel.frame
        guard let cgRect = self.cgTopLeftRect(forNSRect: nsFrame, on: panel.screen) else {
          result(nil); return
        }
        result([
          "x": Double(cgRect.origin.x),
          "y": Double(cgRect.origin.y),
          "width": Double(cgRect.size.width),
          "height": Double(cgRect.size.height),
        ])

      case "getScreenInfo":
        // Return logical size and CG origin of the display under the cursor.
        // Lightweight alternative to captureScreen when only screen info is needed.
        let mouseLocation = NSEvent.mouseLocation
        let allScreens = NSScreen.screens
        let target = allScreens.first(where: { $0.frame.contains(mouseLocation) })
          ?? NSScreen.main ?? allScreens.first!
        guard let displayID = (target.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else {
          result(nil); return
        }
        let cgBounds = CGDisplayBounds(displayID)
        result([
          "screenWidth": Double(target.frame.size.width),
          "screenHeight": Double(target.frame.size.height),
          "screenOriginX": Double(cgBounds.origin.x),
          "screenOriginY": Double(cgBounds.origin.y),
        ])

      case "getScreenInfoForRect":
        guard let args = call.arguments as? [String: Double],
              let x = args["x"],
              let y = args["y"],
              let w = args["width"],
              let h = args["height"] else {
          result(nil); return
        }
        let cgRect = CGRect(x: x, y: y, width: w, height: h)
        let allScreens = NSScreen.screens
        var bestScreen: NSScreen?
        var bestArea: CGFloat = 0

        for screen in allScreens {
          guard let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else {
            continue
          }
          let cgBounds = CGDisplayBounds(displayID)
          let intersection = cgBounds.intersection(cgRect)
          let area = intersection.isNull ? 0 : intersection.width * intersection.height
          if area > bestArea {
            bestArea = area
            bestScreen = screen
          }
        }

        if bestScreen == nil {
          let center = CGPoint(x: x + w / 2, y: y + h / 2)
          bestScreen = allScreens.first(where: { screen in
            guard let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else {
              return false
            }
            let cgBounds = CGDisplayBounds(displayID)
            return cgBounds.contains(center)
          }) ?? NSScreen.main ?? allScreens.first
        }

        guard let target = bestScreen,
              let displayID = (target.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else {
          result(nil); return
        }
        let cgBounds = CGDisplayBounds(displayID)
        result([
          "screenWidth": Double(target.frame.size.width),
          "screenHeight": Double(target.frame.size.height),
          "screenOriginX": Double(cgBounds.origin.x),
          "screenOriginY": Double(cgBounds.origin.y),
        ])

      case "registerTrayShortcuts":
        // Store shortcut mapping; tray_manager handles menu creation and display.
        // We patch keyEquivalent on menu items via didBeginTrackingNotification.
        guard let items = call.arguments as? [[String: Any]] else {
          result(FlutterError(code: "INVALID_ARGS",
                              message: "registerTrayShortcuts requires a list of shortcut dicts",
                              details: nil))
          return
        }
        var shortcuts: [String: (equiv: String, mask: NSEvent.ModifierFlags)] = [:]
        for item in items {
          guard let label = item["label"] as? String,
                let equiv = item["keyEquivalent"] as? String else { continue }
          var mask: NSEvent.ModifierFlags = []
          if let mods = item["modifiers"] as? [String] {
            for mod in mods {
              switch mod {
              case "command": mask.insert(.command)
              case "shift":   mask.insert(.shift)
              case "option":  mask.insert(.option)
              case "control": mask.insert(.control)
              default: break
              }
            }
          }
          shortcuts[label] = (equiv, mask)
        }
        self.trayShortcuts = shortcuts

        // Observe menu tracking to patch items with keyEquivalent before render.
        if let old = self.trayMenuObserver {
          NotificationCenter.default.removeObserver(old)
        }
        self.trayMenuObserver = NotificationCenter.default.addObserver(
          forName: NSMenu.didBeginTrackingNotification,
          object: nil,
          queue: .main
        ) { [weak self] notification in
          guard let self = self,
                let menu = notification.object as? NSMenu else { return }
          for item in menu.items {
            if let shortcut = self.trayShortcuts[item.title] {
              item.keyEquivalent = shortcut.equiv
              item.keyEquivalentModifierMask = shortcut.mask
            }
          }
        }
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

  // MARK: - Flutter surface transparency

  /// Toggle `isOpaque` on the Flutter rendering surface (CAMetalLayer).
  /// Recursively walks the ENTIRE layer tree starting from `contentView.layer`
  /// to catch the CAMetalLayer regardless of how deeply Flutter nests it.
  ///
  /// Previous versions only walked `contentView.subviews` one level deep,
  /// which missed the CAMetalLayer when it was a sublayer of `contentView.layer`
  /// rather than backing a child NSView.
  private func setFlutterSurfaceOpaque(_ opaque: Bool) {
    guard let contentView = contentView else { return }
    contentView.wantsLayer = true
    // Walk the content view's own layer tree — the CAMetalLayer is typically
    // a sublayer here, not the backing layer of any child NSView.
    if let rootLayer = contentView.layer {
      Self.setLayerTreeOpaque(rootLayer, opaque: opaque)
    }
    // Also walk subview layer trees as a safety net.
    for subview in contentView.subviews {
      subview.wantsLayer = true
      if let layer = subview.layer {
        Self.setLayerTreeOpaque(layer, opaque: opaque)
      }
    }
  }

  /// Recursively set `isOpaque` on a layer and ALL its descendants.
  /// When making transparent, also clears `backgroundColor` so the compositor
  /// sees through to the content below.
  private static func setLayerTreeOpaque(_ layer: CALayer, opaque: Bool) {
    layer.isOpaque = opaque
    if !opaque {
      layer.backgroundColor = nil
    }
    layer.sublayers?.forEach { sublayer in
      setLayerTreeOpaque(sublayer, opaque: opaque)
    }
  }

  /// Log the full layer tree for diagnostics (debug builds only).
  private static func dumpLayerTree(_ layer: CALayer, indent: String = "") {
    #if DEBUG
    let typeName = String(describing: type(of: layer))
    let bg: String
    if let comps = layer.backgroundColor?.components {
      bg = comps.map { String(format: "%.1f", $0) }.joined(separator: ",")
    } else {
      bg = "nil"
    }
    log("\(indent)\(typeName): isOpaque=\(layer.isOpaque) bg=[\(bg)] bounds=\(layer.bounds)")
    layer.sublayers?.forEach { sublayer in
      dumpLayerTree(sublayer, indent: indent + "  ")
    }
    #endif
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

  /// Drill down through AX children to find the smallest element containing
  /// [point]. Only recurses into children whose frame contains the point,
  /// keeping the search focused (typically 1-3 children per level).
  private static func drillDownHitTest(
    element: AXUIElement,
    point: CGPoint,
    bestFrame: inout CGRect?,
    bestArea: inout Double,
    depth: Int,
    maxDepth: Int
  ) {
    if depth >= maxDepth { return }

    var childrenValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      element, kAXChildrenAttribute as CFString, &childrenValue
    ) == .success, let children = childrenValue as? [AXUIElement] else { return }

    for child in children {
      guard let frame = frameOfElement(child),
            frame.width >= 10, frame.height >= 10,
            frame.contains(point) else { continue }

      let area = Double(frame.width * frame.height)
      if area < bestArea {
        bestFrame = frame
        bestArea = area
      }
      drillDownHitTest(
        element: child,
        point: point,
        bestFrame: &bestFrame,
        bestArea: &bestArea,
        depth: depth + 1,
        maxDepth: maxDepth
      )
    }
  }

  // MARK: - Esc monitor helpers

  /// Remove both global and local Esc key monitors.
  private func stopEscMonitorImpl() {
    if let monitor = self.globalEscMonitor {
      NSEvent.removeMonitor(monitor)
      self.globalEscMonitor = nil
    }
    if let monitor = self.localEscMonitor {
      NSEvent.removeMonitor(monitor)
      self.localEscMonitor = nil
    }
  }

  /// Remove overlay-only observers/panels/state.
  /// When [restoreStyleMask] is true, also restore the pre-overlay style mask.
  /// When false, keeps current style mask to avoid flash-prone style changes.
  private func cleanupOverlayState(restoreStyleMask: Bool) {
    // Remove scroll stop button panel
    self.scrollStopPanel?.close()
    self.scrollStopPanel = nil
    // Remove floating toolbar panel
    self.toolbarPanel?.close()
    self.toolbarPanel = nil
    self.toolbarContentView = nil
    self.removeToolbarHitTestMonitor()
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
    // Remove Esc monitors (safety net — normally stopped by Dart)
    self.stopEscMonitorImpl()
    self.overlayScreenFrame = nil

    if restoreStyleMask {
      // Force alpha=0 BEFORE changing styleMask.  macOS may briefly redisplay
      // a hidden window when styleMask changes; making it invisible first
      // prevents a visible flash.
      self.alphaValue = 0
      self.styleMask = self.savedStyleMask ?? [.titled, .closable, .miniaturizable, .resizable]
      self.savedStyleMask = nil
      // Alpha stays 0 — Dart callers restore via windowManager.setOpacity(1.0)
      // right before show(), ensuring no intermediate state is visible.
    }
    // No else branch needed — callers that don't show the window (copy/cancel)
    // don't need alpha restored since it resets on next overlay entry.

    // isOpaque stays false — see awakeFromNib comment.
    self.backgroundColor = .windowBackgroundColor
    self.contentView?.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    // Restore Flutter surface opacity (scroll capture sets it transparent).
    self.setFlutterSurfaceOpaque(true)
    self.hasShadow = true
    self.level = .normal
    self.collectionBehavior = [.moveToActiveSpace]
    self.ignoresMouseEvents = false
    self.acceptsMouseMovedEvents = false
  }

  // MARK: - Toolbar hit testing

  private func installToolbarHitTestMonitor() {
    if toolbarHitTestMonitor != nil { return }
    toolbarHitTestMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .leftMouseDown]
    ) { [weak self] event in
      self?.updateToolbarHitTesting()
      return event
    }
  }

  private func removeToolbarHitTestMonitor() {
    if let monitor = toolbarHitTestMonitor {
      NSEvent.removeMonitor(monitor)
      toolbarHitTestMonitor = nil
    }
    if overlayIgnoresMouseForToolbar {
      overlayIgnoresMouseForToolbar = false
      self.ignoresMouseEvents = false
    }
  }

  private func updateToolbarHitTesting() {
    if overlayScreenFrame == nil {
      if overlayIgnoresMouseForToolbar {
        overlayIgnoresMouseForToolbar = false
        self.ignoresMouseEvents = false
      }
      return
    }
    guard let panel = toolbarPanel, panel.isVisible else {
      if overlayIgnoresMouseForToolbar {
        overlayIgnoresMouseForToolbar = false
        self.ignoresMouseEvents = false
      }
      return
    }
    let mouse = NSEvent.mouseLocation
    let isOverToolbar = panel.frame.contains(mouse)
    if isOverToolbar && !overlayIgnoresMouseForToolbar {
      overlayIgnoresMouseForToolbar = true
      self.ignoresMouseEvents = true
    } else if !isOverToolbar && overlayIgnoresMouseForToolbar {
      overlayIgnoresMouseForToolbar = false
      self.ignoresMouseEvents = false
    }
  }

  // MARK: - Cursor helpers

  /// Set a diagonal resize cursor using private NSCursor API.
  ///
  /// Flutter's `SystemMouseCursors.resizeUpLeft` etc. silently fall back to
  /// the arrow cursor on macOS because the Flutter engine's Obj-C bridge
  /// can't reliably invoke the private `_windowResizeNorthWest…` selectors.
  /// Calling them directly from Swift works.
  ///
  /// - Parameter nwse: `true` for NW↔SE diagonal (topLeft / bottomRight),
  ///                   `false` for NE↔SW diagonal (topRight / bottomLeft).
  private func setDiagonalResizeCursor(nwse: Bool) {
    let selectorName = nwse
      ? "_windowResizeNorthWestSouthEastCursor"
      : "_windowResizeNorthEastSouthWestCursor"
    let sel = NSSelectorFromString(selectorName)
    guard NSCursor.responds(to: sel),
          let result = NSCursor.perform(sel),
          let cursor = result.takeUnretainedValue() as? NSCursor
    else { return }  // Unavailable — cursor stays as-is (no regression).
    cursor.set()
  }

  // MARK: - Overlay helpers

  /// Find the target screen from arguments (CG origin) or mouse location,
  /// then configure + show the overlay window on that screen in one shot.
  /// Used for the initial ⌘⇧2 capture.
  private func configureOverlay(_ args: [String: Double]?) {
    let allScreens = NSScreen.screens
    guard !allScreens.isEmpty else { return }

    func cgOrigin(for screen: NSScreen) -> (x: Double, y: Double)? {
      guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
        return nil
      }
      let bounds = CGDisplayBounds(id.uint32Value)
      return (Double(bounds.origin.x), Double(bounds.origin.y))
    }

    let targetScreen: NSScreen
    if let args = args,
       let targetCGX = args["screenOriginX"],
       let targetCGY = args["screenOriginY"] {
      targetScreen = allScreens.first(where: { screen in
        guard let origin = cgOrigin(for: screen) else { return false }
        return abs(origin.x - targetCGX) < 2 && abs(origin.y - targetCGY) < 2
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
    // NOTE: isOpaque stays false permanently (set in awakeFromNib) so the Metal
    // pipeline always uses a transparent clear color. The overlay still looks
    // opaque because RegionSelectionScreen paints every pixel. The solid black
    // backgroundColor/layer backing prevents flash during the initial render.
    self.backgroundColor = .black
    self.contentView?.wantsLayer = true
    self.contentView?.layer?.backgroundColor = NSColor.black.cgColor
    self.hasShadow = false
    self.isMovableByWindowBackground = false
    self.minSize = NSSize(width: 1, height: 1)
    self.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    self.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) - 1)
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
      // Only trigger when the cursor is on a confirmed *different* NSScreen.
      // NSRect.contains uses half-open intervals (minY <= y < maxY), so the
      // cursor at the exact top/right edge of the screen (y == maxY) reads as
      // "outside" even though it's still on the same display.  This caused
      // spurious display-change cycles that baked ghost images into re-captures.
      let mouseIsOnDifferentScreen = NSScreen.screens.contains { screen in
        screen.frame.contains(mouse) &&
          (abs(screen.frame.origin.x - overlayFrame.origin.x) > 2 ||
           abs(screen.frame.origin.y - overlayFrame.origin.y) > 2 ||
           abs(screen.frame.width  - overlayFrame.width)  > 2 ||
           abs(screen.frame.height - overlayFrame.height) > 2)
      }
      if mouseIsOnDifferentScreen {
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

// MARK: - ScrollStopClickView

/// Transparent NSView that acts as a click target for the scroll capture "Done"
/// button.  Placed inside a borderless NSPanel that floats above the Flutter
/// overlay window (which has ignoresMouseEvents = true for scroll passthrough).
private class ScrollStopClickView: NSView {
  var onClick: (() -> Void)?

  override func mouseDown(with event: NSEvent) {
    onClick?()
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .pointingHand)
  }
}

// MARK: - ToolbarContentView

/// Native NSView that draws the annotation toolbar as a dark pill with
/// SF Symbol icon buttons.  Lives inside a borderless NSPanel that floats
/// independently of the Flutter preview window.
@available(macOS 11.0, *)
private struct MaterialIconFont {
  static let cgFont: CGFont? = {
    let bundles = [Bundle.main] + Bundle.allFrameworks
    for bundle in bundles {
      if let url = bundle.url(forResource: "MaterialIcons-Regular",
                              withExtension: "otf",
                              subdirectory: "flutter_assets/fonts") ??
          bundle.url(forResource: "MaterialIcons-Regular",
                     withExtension: "otf") {
        if let provider = CGDataProvider(url: url as CFURL),
           let font = CGFont(provider) {
          return font
        }
      }
    }
    return nil
  }()

  static func font(size: CGFloat) -> NSFont? {
    guard let cgFont else { return nil }
    let ctFont = CTFontCreateWithGraphicsFont(cgFont, size, nil, nil)
    return ctFont as NSFont
  }
}

@available(macOS 11.0, *)
private class ToolbarButton: NSButton {
  // Allow clicks even when the toolbar panel can't become key.
  // Non-activating panels discard mouseDown by default.
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@available(macOS 11.0, *)
private class ToolbarContentView: NSView {

  /// Fired when a button is tapped; argument is the action string
  /// (e.g. "toolTap:rectangle", "undo", "copy").
  var onAction: ((String) -> Void)?

  // ── Action string mapping ──
  private enum ToolbarIcon {
    case material(Int)
    case circledOne
  }

  private enum MaterialIcon {
    static let rectangleOutlined = 0xf0650
    static let circleOutlined = 0xef53
    static let arrowRightAltRounded = 0xf57c
    static let horizontalRuleRounded = 0xf7f8
    static let editOutlined = 0xf00d
    static let brushOutlined = 0xef02
    static let blurOnRounded = 0xf5c9
    static let textFieldsRounded = 0xf021e
    static let titleRounded = 0xf023d
    static let undoRounded = 0xf0261
    static let redoRounded = 0xf00e7
    static let copyRounded = 0xf66c
    static let saveAltRounded = 0xf0125
    static let pushPinOutlined = 0xf2d7
    static let closeRounded = 0xf647
  }

  private static let toolActions: [(icon: ToolbarIcon, action: String, label: String)] = [
    (.material(MaterialIcon.rectangleOutlined), "toolTap:rectangle", "Rectangle"),
    (.material(MaterialIcon.circleOutlined), "toolTap:ellipse", "Ellipse"),
    (.material(MaterialIcon.arrowRightAltRounded), "toolTap:arrow", "Arrow"),
    (.material(MaterialIcon.horizontalRuleRounded), "toolTap:line", "Line"),
    (.material(MaterialIcon.editOutlined), "toolTap:pencil", "Pencil"),
    (.material(MaterialIcon.brushOutlined), "toolTap:marker", "Marker"),
    (.material(MaterialIcon.blurOnRounded), "toolTap:mosaic", "Mosaic"),
    (.circledOne, "toolTap:number", "Number"),
    (.material(MaterialIcon.titleRounded), "toolTap:text", "Text"),
  ]

  // ── Buttons ──
  private var toolButtons: [NSButton] = []
  private var undoButton: NSButton!
  private var redoButton: NSButton!
  private var copyButton: NSButton!
  private var saveButton: NSButton!
  private var pinButton: NSButton!
  private var discardButton: NSButton!

  // ── Active-tool highlight layers (one per tool button) ──
  private var highlightLayers: [CALayer] = []
  private var activeTool: String?
  private var trackingAreaRef: NSTrackingArea?
  private var cursorPushed = false

  deinit {
    if cursorPushed {
      NSCursor.pop()
    }
  }

  override var isOpaque: Bool { false }
  override func draw(_ dirtyRect: NSRect) { /* empty — layer draws background */ }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override var acceptsFirstResponder: Bool { true }
  override var needsPanelToBecomeKey: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true

    // Pill background — drawn by the layer itself.
    // masksToBounds clips any AppKit subview backgrounds to the rounded rect.
    layer!.backgroundColor = NSColor(white: 0.125, alpha: 0.9).cgColor
    layer!.cornerRadius = 22
    layer!.masksToBounds = true

    // Build horizontal stack of buttons.
    let stack = NSStackView()
    stack.orientation = .horizontal
    stack.spacing = 2
    stack.alignment = .centerY
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)

    // Pad 8px horizontally, center vertically.
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])

    // ── Tool buttons ──
    for (index, tool) in Self.toolActions.enumerated() {
      let btn = makeButton(icon: tool.icon, tooltip: tool.label, tag: index)
      toolButtons.append(btn)
      stack.addArrangedSubview(btn)
    }

    // ── Spacing before undo/redo ──
    let spacer1 = NSView()
    spacer1.translatesAutoresizingMaskIntoConstraints = false
    spacer1.widthAnchor.constraint(equalToConstant: 2).isActive = true
    stack.addArrangedSubview(spacer1)

    // ── Undo / Redo ──
    undoButton = makeButton(
      icon: .material(MaterialIcon.undoRounded),
      tooltip: "Undo",
      tag: 100
    )
    redoButton = makeButton(
      icon: .material(MaterialIcon.redoRounded),
      tooltip: "Redo",
      tag: 101
    )
    undoButton.isEnabled = false
    redoButton.isEnabled = false
    stack.addArrangedSubview(undoButton)
    stack.addArrangedSubview(redoButton)

    // ── Divider ──
    let divider = NSView()
    divider.wantsLayer = true
    divider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
    divider.translatesAutoresizingMaskIntoConstraints = false
    divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
    divider.heightAnchor.constraint(equalToConstant: 18).isActive = true
    let dividerWrap = NSStackView()
    dividerWrap.orientation = .horizontal
    dividerWrap.spacing = 4
    dividerWrap.addArrangedSubview(NSView()) // spacer
    dividerWrap.addArrangedSubview(divider)
    dividerWrap.addArrangedSubview(NSView()) // spacer
    // Make the spacer views collapse to zero width
    for v in dividerWrap.arrangedSubviews where v !== divider {
      v.widthAnchor.constraint(equalToConstant: 2).isActive = true
    }
    stack.addArrangedSubview(dividerWrap)

    // ── Action buttons ──
    copyButton = makeButton(
      icon: .material(MaterialIcon.copyRounded),
      tooltip: "Copy",
      tag: 200
    )
    saveButton = makeButton(
      icon: .material(MaterialIcon.saveAltRounded),
      tooltip: "Save",
      tag: 201
    )
    pinButton = makeButton(
      icon: .material(MaterialIcon.pushPinOutlined),
      tooltip: "Pin",
      tag: 202
    )
    discardButton = makeButton(
      icon: .material(MaterialIcon.closeRounded),
      tooltip: "Discard",
      tag: 203
    )
    discardButton.contentTintColor = NSColor(red: 0.94, green: 0.6, blue: 0.6, alpha: 1.0)
    stack.addArrangedSubview(copyButton)
    stack.addArrangedSubview(saveButton)
    stack.addArrangedSubview(pinButton)
    stack.addArrangedSubview(discardButton)

    // ── Highlight layers for tool buttons ──
    for btn in toolButtons {
      let hl = CALayer()
      hl.backgroundColor = NSColor.clear.cgColor
      hl.cornerRadius = 17
      btn.layer?.insertSublayer(hl, at: 0)
      highlightLayers.append(hl)
    }
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

  // ── Layout ──

  override func layout() {
    super.layout()
    // Resize highlight layers to match button bounds.
    for (index, btn) in toolButtons.enumerated() {
      highlightLayers[index].frame = btn.bounds
    }
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingAreaRef {
      removeTrackingArea(trackingAreaRef)
    }
    let options: NSTrackingArea.Options = [
      .activeAlways,
      .mouseEnteredAndExited,
      .cursorUpdate,
      .inVisibleRect,
    ]
    let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
    addTrackingArea(area)
    trackingAreaRef = area
  }

  // ── Button factory ──

  private func makeButton(icon: ToolbarIcon, tooltip: String, tag: Int) -> NSButton {
    let btn = ToolbarButton(frame: NSRect(x: 0, y: 0, width: 34, height: 34))
    btn.bezelStyle = .regularSquare
    btn.isBordered = false
    btn.imagePosition = .imageOnly
    btn.imageScaling = .scaleNone
    btn.toolTip = tooltip
    btn.tag = tag
    btn.target = self
    btn.action = #selector(buttonClicked(_:))
    btn.wantsLayer = true
    btn.layer?.backgroundColor = NSColor.clear.cgColor
    btn.translatesAutoresizingMaskIntoConstraints = false
    btn.widthAnchor.constraint(equalToConstant: 34).isActive = true
    btn.heightAnchor.constraint(equalToConstant: 34).isActive = true
    btn.image = iconImage(for: icon, tooltip: tooltip)
    if btn.image == nil {
      btn.title = tooltip
      btn.imagePosition = .noImage
      btn.font = NSFont.systemFont(ofSize: 11, weight: .medium)
    }
    btn.contentTintColor = .white
    return btn
  }

  private func iconImage(for icon: ToolbarIcon, tooltip: String) -> NSImage? {
    switch icon {
    case .material(let codepoint):
      return materialIconImage(codepoint: codepoint)
    case .circledOne:
      return circledOneImage()
    }
  }

  private func materialIconImage(codepoint: Int) -> NSImage? {
    guard let scalar = UnicodeScalar(codepoint),
          let font = MaterialIconFont.font(size: 18) else {
      return nil
    }
    let string = String(scalar)
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: NSColor.white
    ]
    let attributed = NSAttributedString(string: string, attributes: attributes)
    let glyphSize = attributed.size()
    let pad: CGFloat = 2
    let imageSize = NSSize(
      width: ceil(glyphSize.width + pad),
      height: ceil(glyphSize.height + pad)
    )
    let image = NSImage(size: imageSize)
    image.lockFocus()
    let origin = NSPoint(
      x: (imageSize.width - glyphSize.width) / 2,
      y: (imageSize.height - glyphSize.height) / 2
    )
    attributed.draw(at: origin)
    image.unlockFocus()
    image.isTemplate = true
    return image
  }

  private func circledOneImage() -> NSImage {
    let size: CGFloat = 18
    let strokeWidth: CGFloat = 1.5
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let inset = strokeWidth / 2
    let rect = NSRect(
      x: inset,
      y: inset,
      width: size - strokeWidth,
      height: size - strokeWidth
    )
    let path = NSBezierPath(ovalIn: rect)
    NSColor.white.setStroke()
    path.lineWidth = strokeWidth
    path.stroke()
    let text = "1"
    let font = NSFont.systemFont(ofSize: size * 0.55, weight: .bold)
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: NSColor.white
    ]
    let textSize = text.size(withAttributes: attributes)
    let origin = NSPoint(
      x: (size - textSize.width) / 2,
      y: (size - textSize.height) / 2 - 1
    )
    text.draw(at: origin, withAttributes: attributes)
    image.unlockFocus()
    image.isTemplate = true
    return image
  }

  // ── Click handler ──

  @objc private func buttonClicked(_ sender: NSButton) {
    let tag = sender.tag
    let action: String
    if tag < Self.toolActions.count {
      action = Self.toolActions[tag].action
    } else {
      switch tag {
      case 100: action = "undo"
      case 101: action = "redo"
      case 200: action = "copy"
      case 201: action = "save"
      case 202: action = "pin"
      case 203: action = "discard"
      default: return
      }
    }
    onAction?(action)
  }

  // ── State sync ──

  func updateState(
    activeTool: String?,
    canUndo: Bool,
    canRedo: Bool,
    hasAnnotations: Bool,
    showsPin: Bool
  ) {
    self.activeTool = activeTool

    // Tool highlight
    for (index, tool) in Self.toolActions.enumerated() {
      let isActive = (tool.action == "toolTap:\(activeTool ?? "")")
      highlightLayers[index].backgroundColor = isActive
        ? NSColor.white.withAlphaComponent(0.15).cgColor
        : NSColor.clear.cgColor
    }

    // Undo / Redo
    undoButton.isEnabled = canUndo
    undoButton.alphaValue = canUndo ? 1.0 : 0.3
    redoButton.isEnabled = canRedo
    redoButton.alphaValue = canRedo ? 1.0 : 0.3

    pinButton.isHidden = !showsPin
  }

  // ── Cursor ──

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .arrow)
  }

  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    if !cursorPushed {
      NSCursor.arrow.push()
      cursorPushed = true
    }
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    if cursorPushed {
      NSCursor.pop()
      cursorPushed = false
    }
  }

  override func cursorUpdate(with event: NSEvent) {
    NSCursor.arrow.set()
  }
}

// MARK: - PinnedImagePanel

/// Floating panel that displays a pinned screenshot as a sticker.
/// Supports drag-to-move, Space to edit, Escape to close.
private class PinnedImagePanel: NSPanel {
  var onEdit: (() -> Void)?
  var onClose: (() -> Void)?

  override var canBecomeKey: Bool { true }

  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 49: // Space → edit
      onEdit?()
    case 53: // Escape → close
      let closeCallback = onClose
      self.close()
      closeCallback?()
    default:
      break // Suppress system beep for all keys.
    }
  }
}

// MARK: - PinnedImageView

/// NSView that draws a pinned image scaled to fill its bounds.
private class PinnedImageView: NSView {
  var displayImage: NSImage?

  override var isOpaque: Bool { true }
  override var mouseDownCanMoveWindow: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseDown(with event: NSEvent) {
    // Make the panel key so it receives keyboard events (Space/Escape)
    // BEFORE the drag gesture starts. Without this, isMovableByWindowBackground
    // consumes the click and the panel never becomes key.
    window?.makeKey()
    super.mouseDown(with: event)
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let image = displayImage else {
      NSColor.black.setFill()
      dirtyRect.fill()
      return
    }
    image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1.0)
  }
}
