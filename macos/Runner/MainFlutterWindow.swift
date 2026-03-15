import ApplicationServices
import Carbon
import Cocoa
import CoreGraphics
import FlutterMacOS
import ServiceManagement

class MainFlutterWindow: NSWindow {
  private struct HotKeyChannelError: Error {
    let code: String
    let message: String
    let details: Any?
  }

  private static let hotKeySignature: OSType = 0x41534E50

  private var savedStyleMask: NSWindow.StyleMask?
  private var flutterChannel: FlutterMethodChannel?
  private var hotkeyChannel: FlutterMethodChannel?
  private var shortcutRecorderChannel: FlutterMethodChannel?
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

  // Shortcut mapping for patching tray_manager NSMenu items with keyEquivalent.
  // Keys are menu item titles, values are (keyEquivalent, modifierMask).
  private var trayShortcuts: [String: (equiv: String, mask: NSEvent.ModifierFlags)] = [:]
  private var trayMenuObserver: NSObjectProtocol?

  // Tiny borderless panel placed over the Flutter "Done" button so it receives
  // mouse clicks even though the main overlay has ignoresMouseEvents = true.
  private var scrollStopPanel: NSPanel?

  // Floating toolbar panel displayed outside the main Flutter window bounds.
  private var toolbarPanel: NSPanel?
  private var toolbarButtons: [String: NSButton] = [:]
  private var pendingToolbarArgs: [String: Any]?
  private var lastToolbarArgs: [String: Any]?
  private var latestToolbarRequestId = 0
  private var latestToolbarSessionId: Int64?
  private var toolbarMoveRefreshWorkItem: DispatchWorkItem?
  private var windowDidMoveObserver: NSObjectProtocol?
  private var windowDidResizeObserver: NSObjectProtocol?

  // Pinned image panels — floating stickers that persist across captures.
  private var pinnedPanels: [Int64: PinnedImagePanel] = [:]
  private var nextPinnedPanelId: Int64 = 0
  private var hotKeyEventHandler: EventHandlerRef?
  private var registeredHotKeys: [String: EventHotKeyRef] = [:]
  private var hotKeyActionsById: [UInt32: String] = [:]
  private var nextHotKeyRegistrationId: UInt32 = 1
  private var shortcutRecorderMonitor: Any?

  private func screenAndBounds(forCGPoint point: CGPoint) -> (NSScreen, CGRect)? {
    for screen in NSScreen.screens {
      guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
      else {
        continue
      }
      let bounds = CGDisplayBounds(id.uint32Value)
      if bounds.contains(point) {
        return (screen, bounds)
      }
    }
    if let main = NSScreen.main,
      let id = main.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    {
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
    guard
      let displayID =
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
        .uint32Value
    else {
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

  /// Find the most likely screen for a global NS rect (bottom-left origin).
  private func screenForRect(_ rect: NSRect) -> NSScreen? {
    let mid = NSPoint(x: rect.midX, y: rect.midY)
    return NSScreen.screens.first(where: { $0.frame.contains(mid) }) ?? NSScreen.main
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

  private func launchAtLoginStatePayload() -> [String: Any] {
    guard #available(macOS 13.0, *) else {
      return [
        "supported": false,
        "enabled": false,
        "requiresApproval": false,
      ]
    }

    let status = SMAppService.mainApp.status
    return [
      "supported": true,
      "enabled": status == .enabled || status == .requiresApproval,
      "requiresApproval": status == .requiresApproval,
    ]
  }

  private func installHotKeyEventHandlerIfNeeded() throws {
    if hotKeyEventHandler != nil {
      return
    }

    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )
    var eventHandler: EventHandlerRef?

    let status = InstallEventHandler(
      GetEventDispatcherTarget(),
      { _, eventRef, userData in
        guard let userData else {
          return noErr
        }
        let window = Unmanaged<MainFlutterWindow>.fromOpaque(userData).takeUnretainedValue()
        return window.handleRegisteredHotKey(eventRef)
      },
      1,
      &eventType,
      UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
      &eventHandler
    )

    guard status == noErr, let eventHandler else {
      throw HotKeyChannelError(
        code: "HOTKEY_HANDLER_INSTALL_FAILED",
        message: "Failed to install native hotkey handler.",
        details: Int(status)
      )
    }

    hotKeyEventHandler = eventHandler
  }

  private func handleRegisteredHotKey(_ eventRef: EventRef?) -> OSStatus {
    guard let eventRef else {
      return noErr
    }

    var hotKeyID = EventHotKeyID()
    let status = withUnsafeMutablePointer(to: &hotKeyID) { hotKeyIDPointer in
      GetEventParameter(
        eventRef,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        hotKeyIDPointer
      )
    }

    guard status == noErr else {
      return status
    }
    guard hotKeyID.signature == Self.hotKeySignature,
      let action = hotKeyActionsById[hotKeyID.id]
    else {
      return noErr
    }

    DispatchQueue.main.async { [weak self] in
      self?.hotkeyChannel?.invokeMethod(
        "onShortcutTriggered",
        arguments: ["action": action]
      )
    }
    return noErr
  }

  private func setRegisteredHotKeys(_ items: [[String: Any]]) throws {
    try installHotKeyEventHandlerIfNeeded()
    unregisterAllRegisteredHotKeys()

    do {
      for item in items {
        try registerHotKey(item)
      }
    } catch {
      unregisterAllRegisteredHotKeys()
      throw error
    }
  }

  private func registerHotKey(_ item: [String: Any]) throws {
    guard let action = item["action"] as? String, !action.isEmpty else {
      throw HotKeyChannelError(
        code: "INVALID_ARGS",
        message: "Hotkey registration requires an action.",
        details: nil
      )
    }
    guard let keyCodeNumber = item["keyCode"] as? NSNumber else {
      throw HotKeyChannelError(
        code: "INVALID_ARGS",
        message: "Hotkey registration requires a keyCode.",
        details: item
      )
    }

    let modifiers = item["modifiers"] as? [String] ?? []
    var hotKeyID = EventHotKeyID()
    hotKeyID.signature = Self.hotKeySignature
    hotKeyID.id = nextHotKeyRegistrationId

    var hotKeyRef: EventHotKeyRef?
    let status = RegisterEventHotKey(
      keyCodeNumber.uint32Value,
      carbonHotKeyModifiers(from: modifiers),
      hotKeyID,
      GetEventDispatcherTarget(),
      OptionBits(kEventHotKeyNoOptions),
      &hotKeyRef
    )

    guard status == noErr, let hotKeyRef else {
      throw HotKeyChannelError(
        code: "HOTKEY_REGISTER_FAILED",
        message: "Failed to register \(action) shortcut.",
        details: Int(status)
      )
    }

    registeredHotKeys[action] = hotKeyRef
    hotKeyActionsById[hotKeyID.id] = action
    nextHotKeyRegistrationId += 1
  }

  private func unregisterAllRegisteredHotKeys() {
    for hotKeyRef in registeredHotKeys.values {
      UnregisterEventHotKey(hotKeyRef)
    }
    registeredHotKeys.removeAll()
    hotKeyActionsById.removeAll()
    nextHotKeyRegistrationId = 1
  }

  private func carbonHotKeyModifiers(from modifiers: [String]) -> UInt32 {
    var flags: UInt32 = 0

    for modifier in modifiers {
      switch modifier {
      case "meta":
        flags |= UInt32(cmdKey)
      case "shift":
        flags |= UInt32(shiftKey)
      case "alt":
        flags |= UInt32(optionKey)
      case "control":
        flags |= UInt32(controlKey)
      case "fn":
        flags |= UInt32(kEventKeyModifierFnMask)
      case "capsLock":
        flags |= UInt32(alphaLock)
      default:
        break
      }
    }

    return flags
  }

  private func startShortcutRecorder() {
    stopShortcutRecorder()

    let mask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged]
    shortcutRecorderMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) {
      [weak self] event in
      guard let self = self else {
        return event
      }
      return self.handleShortcutRecorderEvent(event)
    }

    shortcutRecorderChannel?.invokeMethod(
      "onShortcutRecorderChanged",
      arguments: ["modifiers": [String]()]
    )
  }

  private func stopShortcutRecorder() {
    if let shortcutRecorderMonitor {
      NSEvent.removeMonitor(shortcutRecorderMonitor)
      self.shortcutRecorderMonitor = nil
    }
  }

  private func handleShortcutRecorderEvent(_ event: NSEvent) -> NSEvent? {
    switch event.type {
    case .flagsChanged:
      shortcutRecorderChannel?.invokeMethod(
        "onShortcutRecorderChanged",
        arguments: ["modifiers": shortcutRecorderModifierNames(from: event.modifierFlags)]
      )
      return nil
    case .keyDown:
      if event.keyCode == 53 {
        shortcutRecorderChannel?.invokeMethod("onShortcutRecorderCancelled", arguments: nil)
        return nil
      }
      if event.isARepeat {
        return nil
      }

      shortcutRecorderChannel?.invokeMethod(
        "onShortcutRecorderCaptured",
        arguments: [
          "keyCode": Int(event.keyCode),
          "modifiers": shortcutRecorderModifierNames(from: event.modifierFlags),
        ]
      )
      return nil
    default:
      return event
    }
  }

  private func shortcutRecorderModifierNames(from flags: NSEvent.ModifierFlags) -> [String] {
    let deviceIndependentFlags = flags.intersection(.deviceIndependentFlagsMask)
    var modifiers: [String] = []

    if deviceIndependentFlags.contains(.control) {
      modifiers.append("control")
    }
    if deviceIndependentFlags.contains(.command) {
      modifiers.append("meta")
    }
    if deviceIndependentFlags.contains(.option) {
      modifiers.append("alt")
    }
    if deviceIndependentFlags.contains(.shift) {
      modifiers.append("shift")
    }
    if deviceIndependentFlags.contains(.function) {
      modifiers.append("fn")
    }
    if deviceIndependentFlags.contains(.capsLock) {
      modifiers.append("capsLock")
    }

    return modifiers
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
    let hotkeyChannel = FlutterMethodChannel(
      name: "com.asnap/hotkeys",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    self.hotkeyChannel = hotkeyChannel
    let shortcutRecorderChannel = FlutterMethodChannel(
      name: "com.asnap/shortcutRecorder",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    self.shortcutRecorderChannel = shortcutRecorderChannel
    hotkeyChannel.setMethodCallHandler { [weak self] (call, result) in
      guard let self = self else {
        result(nil)
        return
      }

      switch call.method {
      case "setHotkeys":
        guard let items = call.arguments as? [[String: Any]] else {
          result(
            FlutterError(
              code: "INVALID_ARGS",
              message: "setHotkeys requires a list of shortcut dictionaries",
              details: nil))
          return
        }

        do {
          try self.setRegisteredHotKeys(items)
          result(nil)
        } catch let error as HotKeyChannelError {
          result(
            FlutterError(
              code: error.code,
              message: error.message,
              details: error.details))
        } catch {
          result(
            FlutterError(
              code: "HOTKEY_ERROR",
              message: error.localizedDescription,
              details: nil))
        }
      case "unregisterAll":
        self.unregisterAllRegisteredHotKeys()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    shortcutRecorderChannel.setMethodCallHandler { [weak self] (call, result) in
      guard let self = self else {
        result(nil)
        return
      }

      switch call.method {
      case "start":
        self.startShortcutRecorder()
        result(nil)
      case "stop":
        self.stopShortcutRecorder()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
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
        guard !allScreens.isEmpty else {
          result(nil)
          return
        }

        let cgImage: CGImage?
        let logicalWidth: Double
        let logicalHeight: Double
        let cgOriginX: Double
        let cgOriginY: Double

        if allDisplays {
          // Union of all display bounds in CG coordinates (top-left origin)
          var dCount: UInt32 = 0
          guard CGGetActiveDisplayList(0, nil, &dCount) == .success, dCount > 0 else {
            result(nil)
            return
          }
          var dIDs = [CGDirectDisplayID](repeating: 0, count: Int(dCount))
          guard CGGetActiveDisplayList(dCount, &dIDs, &dCount) == .success, dCount > 0 else {
            result(nil)
            return
          }
          var unionCG = CGDisplayBounds(dIDs[0])
          for i in 1..<Int(dCount) { unionCG = unionCG.union(CGDisplayBounds(dIDs[i])) }

          cgImage = CGWindowListCreateImage(
            unionCG, .optionOnScreenOnly, kCGNullWindowID, .bestResolution
          )
          let nsUnion = allScreens.reduce(allScreens[0].frame) { $0.union($1.frame) }
          logicalWidth = Double(nsUnion.size.width)
          logicalHeight = Double(nsUnion.size.height)
          cgOriginX = Double(unionCG.origin.x)
          cgOriginY = Double(unionCG.origin.y)
        } else {
          // Single display under the cursor
          let mouseLocation = NSEvent.mouseLocation
          let target =
            allScreens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main ?? allScreens[0]
          guard
            let displayID =
              (target.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
              .uint32Value
          else {
            result(nil)
            return
          }
          MainFlutterWindow.log(
            "captureScreen: mouse=\(mouseLocation) targetFrame=\(NSStringFromRect(target.frame)) displayID=\(displayID)"
          )
          cgImage = CGDisplayCreateImage(displayID)
          logicalWidth = Double(target.frame.size.width)
          logicalHeight = Double(target.frame.size.height)
          let cgBounds = CGDisplayBounds(displayID)
          cgOriginX = Double(cgBounds.origin.x)
          cgOriginY = Double(cgBounds.origin.y)
          MainFlutterWindow.log(
            "  capture size=\(cgImage?.width ?? 0)x\(cgImage?.height ?? 0) logical=\(logicalWidth)x\(logicalHeight) cgOrigin=(\(cgOriginX),\(cgOriginY))"
          )
        }

        guard let img = cgImage else {
          result(nil)
          return
        }

        // Force-convert to BGRA8888 via CGContext — CGWindowListCreateImage
        // doesn't guarantee a specific pixel format.  Dart side decodes with
        // PixelFormat.bgra8888 so the bytes must match exactly.
        let w = img.width
        let h = img.height
        let bpr = w * 4
        guard
          let ctx = CGContext(
            data: nil,
            width: w, height: h,
            bitsPerComponent: 8,
            bytesPerRow: bpr,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
              | CGBitmapInfo.byteOrder32Little.rawValue
          )
        else {
          result(nil)
          return
        }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let baseAddr = ctx.data else {
          result(nil)
          return
        }
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
      case "getScreenInfoForPoint":
        guard let args = call.arguments as? [String: Any] else {
          result(nil)
          return
        }
        let x = (args["x"] as? NSNumber)?.doubleValue ?? (args["x"] as? Double)
        let y = (args["y"] as? NSNumber)?.doubleValue ?? (args["y"] as? Double)
        guard let x, let y else {
          result(nil)
          return
        }
        guard let (screen, bounds) = self.screenAndBounds(forCGPoint: CGPoint(x: x, y: y)) else {
          result(nil)
          return
        }
        result([
          "screenWidth": Double(screen.frame.width),
          "screenHeight": Double(screen.frame.height),
          "screenOriginX": Double(bounds.origin.x),
          "screenOriginY": Double(bounds.origin.y),
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
          result(
            FlutterError(
              code: "INVALID_ARGS",
              message: "repositionOverlay requires screenOriginX/Y",
              details: nil))
          return
        }
        let allScreens = NSScreen.screens
        guard !allScreens.isEmpty else {
          result(nil)
          return
        }

        let targetCGX = args["screenOriginX"] ?? 0
        let targetCGY = args["screenOriginY"] ?? 0
        let targetScreen =
          allScreens.first(where: { screen in
            guard
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? NSNumber
            else {
              return false
            }
            let bounds = CGDisplayBounds(id.uint32Value)
            return abs(Double(bounds.origin.x) - targetCGX) < 2
              && abs(Double(bounds.origin.y) - targetCGY) < 2
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
        // Trigger any deferred toolbar update now that the overlay is visible.
        if let args = self.pendingToolbarArgs {
          self.showOrUpdateToolbarPanel(args)
        }
        MainFlutterWindow.log("revealOverlay: alpha=1")
        result(nil)
      case "resizeToRect":
        // Shrink the borderless overlay window to the selection rect for in-place preview.
        // Stays borderless (no corner radius) and floating above other windows.
        guard let args = call.arguments as? [String: Double],
          let x = args["x"],
          let y = args["y"],
          let w = args["width"],
          let h = args["height"]
        else {
          result(
            FlutterError(
              code: "INVALID_ARGS",
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
        self.hasShadow = false
        self.collectionBehavior = [.moveToActiveSpace]
        self.acceptsMouseMovedEvents = false
        // Keep non-image margins transparent so toolbar can float outside
        // the selected region without showing a dark framed window.
        self.backgroundColor = .clear
        self.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        self.setFlutterSurfaceOpaque(false)
        // Clear constraints so the window can resize freely
        self.minSize = NSSize(width: 1, height: 1)
        self.maxSize = NSSize(
          width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
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
        self.globalEscMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) {
          [weak self] event in
          if event.keyCode == 53 {  // Escape
            DispatchQueue.main.async {
              self?.flutterChannel?.invokeMethod("onEscPressed", arguments: nil)
            }
          }
        }
        // Local monitor: catches Esc when our window IS key but at alpha=0
        self.localEscMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
          [weak self] event in
          if event.keyCode == 53 {  // Escape
            DispatchQueue.main.async {
              self?.flutterChannel?.invokeMethod("onEscPressed", arguments: nil)
            }
            return nil  // consume the event
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
        let includeAxChildren =
          (call.arguments as? [String: Any])?["includeAxChildren"] as? Bool ?? false
        self.startRectPolling(includeAxChildren: includeAxChildren)
        result(nil)
      case "stopRectPolling":
        self.stopRectPolling()
        result(nil)
      case "registerTrayShortcuts":
        // tray_manager builds NSMenu natively, but doesn't expose macOS
        // keyEquivalent in its Dart API. Patch shortcuts before menu display.
        guard let items = call.arguments as? [[String: Any]] else {
          result(
            FlutterError(
              code: "INVALID_ARGS",
              message: "registerTrayShortcuts requires a list of shortcut dicts",
              details: nil))
          return
        }

        var shortcuts: [String: (equiv: String, mask: NSEvent.ModifierFlags)] = [:]
        for item in items {
          guard let label = item["label"] as? String,
            let equiv = item["keyEquivalent"] as? String
          else { continue }

          let mods = item["modifiers"] as? [String] ?? []
          let mask = self.shortcutModifierMask(from: mods)
          shortcuts[label] = (equiv, mask)
        }
        self.trayShortcuts = shortcuts

        if let old = self.trayMenuObserver {
          NotificationCenter.default.removeObserver(old)
          self.trayMenuObserver = nil
        }
        self.trayMenuObserver = NotificationCenter.default.addObserver(
          forName: NSMenu.didBeginTrackingNotification,
          object: nil,
          queue: .main
        ) { [weak self] notification in
          guard let self = self,
            let menu = notification.object as? NSMenu
          else { return }
          self.patchTrayMenuShortcuts(menu)
        }
        result(nil)
      case "getLaunchAtLoginState":
        result(self.launchAtLoginStatePayload())
      case "setLaunchAtLoginEnabled":
        guard let args = call.arguments as? [String: Any],
          let enabled = args["enabled"] as? Bool
        else {
          result(
            FlutterError(
              code: "INVALID_ARGS",
              message: "setLaunchAtLoginEnabled requires an enabled flag",
              details: nil))
          return
        }

        guard #available(macOS 13.0, *) else {
          result(self.launchAtLoginStatePayload())
          return
        }

        let service = SMAppService.mainApp
        let currentStatus = service.status
        if enabled,
          currentStatus == .enabled || currentStatus == .requiresApproval
        {
          result(self.launchAtLoginStatePayload())
          return
        }
        if !enabled, currentStatus == .notRegistered {
          result(self.launchAtLoginStatePayload())
          return
        }

        do {
          if enabled {
            try service.register()
          } else {
            try service.unregister()
          }
        } catch {
          let nsError = error as NSError
          result(
            FlutterError(
              code: "LAUNCH_AT_LOGIN_ERROR",
              message: nsError.localizedDescription,
              details: [
                "domain": nsError.domain,
                "code": nsError.code,
              ]))
          return
        }
        result(self.launchAtLoginStatePayload())
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
          let cgX = args["x"], let cgY = args["y"]
        else {
          result(nil)
          return
        }
        let point = CGPoint(x: cgX, y: cgY)
        let ownPID = ProcessInfo.processInfo.processIdentifier

        // Find which app window sits at this position (skip our own).
        guard
          let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
          ) as? [[String: Any]]
        else {
          result(nil)
          return
        }

        var targetPID: Int32?
        for info in infoList {
          guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
          guard let pid = info[kCGWindowOwnerPID as String] as? Int32, pid != ownPID else {
            continue
          }
          guard let bd = info[kCGWindowBounds as String] as? NSDictionary,
            let bounds = CGRect(dictionaryRepresentation: bd)
          else { continue }
          if bounds.contains(point) {
            targetPID = pid
            break  // front-to-back order → first hit is the topmost
          }
        }
        guard let pid = targetPID, AXIsProcessTrusted() else {
          result(nil)
          return
        }

        let appElement = AXUIElementCreateApplication(pid)
        var axElement: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(appElement, Float(cgX), Float(cgY), &axElement)
        guard err == .success, let element = axElement else {
          result(nil)
          return
        }

        // Start with the returned element's frame.
        var bestFrame: CGRect? = nil
        var bestArea = Double.infinity
        if let frame = MainFlutterWindow.frameOfElement(element),
          frame.width >= 10, frame.height >= 10
        {
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
            guard
              AXUIElementCopyAttributeValue(
                el, kAXParentAttribute as CFString, &parentValue
              ) == .success, CFGetTypeID(parentValue!) == AXUIElementGetTypeID()
            else { break }
            let parent = parentValue as! AXUIElement
            if let frame = MainFlutterWindow.frameOfElement(parent),
              frame.width >= 10, frame.height >= 10
            {
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
          let h = args["height"]
        else {
          result(
            FlutterError(
              code: "INVALID_ARGS",
              message: "captureRegion requires x, y, width, height",
              details: nil))
          return
        }
        guard w > 0, h > 0 else {
          result(
            FlutterError(
              code: "INVALID_ARGS",
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
        guard let img else {
          result(nil)
          return
        }

        let imgW = img.width
        let imgH = img.height
        let bpr = imgW * 4
        guard
          let ctx = CGContext(
            data: nil, width: imgW, height: imgH,
            bitsPerComponent: 8, bytesPerRow: bpr,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
              | CGBitmapInfo.byteOrder32Little.rawValue
          )
        else {
          result(nil)
          return
        }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: imgW, height: imgH))
        guard let baseAddr = ctx.data else {
          result(nil)
          return
        }
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
          let h = args["height"]
        else {
          result(nil)
          return
        }
        guard w > 0, h > 0 else {
          result(nil)
          return
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
      case "showToolbarPanel":
        guard let args = call.arguments as? [String: Any] else {
          result(
            FlutterError(
              code: "INVALID_ARGS",
              message: "showToolbarPanel requires arguments",
              details: nil))
          return
        }
        self.showOrUpdateToolbarPanel(args)
        result(nil)
      case "hideToolbarPanel":
        let args = call.arguments as? [String: Any]
        if let args {
          self.adoptToolbarSessionIfNeeded(args)
        }
        let requestId =
          (args?["requestId"] as? NSNumber)?.intValue ?? (args?["requestId"] as? Int)
          ?? self.latestToolbarRequestId
        self.hideToolbarPanel(minRequestId: requestId)
        result(nil)
      case "resetToolbarPanelState":
        self.resetToolbarPanelState()
        result(nil)
      case "revealPreviewWindow":
        self.alphaValue = 1.0
        self.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Trigger any pending toolbar update now that the window is visible.
        if let args = self.pendingToolbarArgs {
          self.showOrUpdateToolbarPanel(args)
        }
        result(nil)

      // MARK: Pinned image panel
      case "pinImage":
        guard let args = call.arguments as? [String: Any],
          let typedData = args["bytes"] as? FlutterStandardTypedData,
          let width = args["width"] as? Int,
          let height = args["height"] as? Int
        else {
          MainFlutterWindow.log("pinImage: INVALID ARGS — missing bytes/width/height")
          result(nil)
          return
        }
        let bytes = typedData.data
        MainFlutterWindow.log("pinImage: \(width)x\(height), bytes=\(bytes.count)")
        guard width > 0, height > 0, bytes.count >= width * height * 4 else {
          MainFlutterWindow.log("pinImage: INVALID size or bytes too short")
          result(nil)
          return
        }

        // Create NSImage from raw RGBA bytes.
        guard
          let bitmapRep = NSBitmapImageRep(
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
          )
        else {
          result(nil)
          return
        }
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
          let fh = args["frameHeight"] as? Double
        {
          // CG coordinates (top-left origin) → NS coordinates (bottom-left origin).
          let cgRect = CGRect(x: fx, y: fy, width: fw, height: fh)
          let nsOrig = self.nsOrigin(forCGTopLeftRect: cgRect)
          panelFrame = NSRect(origin: nsOrig, size: cgRect.size)
        } else {
          panelFrame = self.frame
        }
        self.nextPinnedPanelId += 1
        let panelId = self.nextPinnedPanelId
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
            self?.flutterChannel?.invokeMethod(
              "onEditPinnedImage",
              arguments: ["panelId": panelId]
            )
          }
        }
        panel.onClose = { [weak self] in
          DispatchQueue.main.async {
            self?.pinnedPanels.removeValue(forKey: panelId)
            self?.flutterChannel?.invokeMethod(
              "onPinnedImageClosed",
              arguments: ["panelId": panelId]
            )
          }
        }

        self.pinnedPanels[panelId] = panel
        panel.makeKeyAndOrderFront(nil)
        MainFlutterWindow.log(
          "pinImage: panelId=\(panelId) created at \(NSStringFromRect(panelFrame))")
        result(panelId)

      case "closePinnedImage":
        let args = call.arguments as? [String: Any]
        if let panelIdNumber = args?["panelId"] as? NSNumber {
          let panelId = panelIdNumber.int64Value
          self.pinnedPanels[panelId]?.close()
        } else {
          let panels = Array(self.pinnedPanels.values)
          for panel in panels {
            panel.close()
          }
        }
        result(nil)

      case "getPinnedPanelFrame":
        let args = call.arguments as? [String: Any]
        let panelId =
          (args?["panelId"] as? NSNumber)?.int64Value
          ?? (args?["panelId"] as? Int64)
          ?? ((args?["panelId"] as? Int).map { Int64($0) })

        let panel: PinnedImagePanel?
        if let panelId {
          panel = self.pinnedPanels[panelId]
        } else {
          panel =
            self.pinnedPanels.values.first(where: { $0.isKeyWindow })
            ?? Array(self.pinnedPanels.values).last
        }
        guard let panel else {
          result(nil)
          return
        }
        let nsFrame = panel.frame
        let screen = screenForRect(nsFrame)
        guard let cgRect = self.cgTopLeftRect(forNSRect: nsFrame, on: screen) else {
          result(nil)
          return
        }
        MainFlutterWindow.log("getPinnedPanelFrame: nsFrame=\(nsFrame), cgRect=\(cgRect)")
        result([
          "x": Double(cgRect.origin.x),
          "y": Double(cgRect.origin.y),
          "width": Double(cgRect.size.width),
          "height": Double(cgRect.size.height),
        ])

      default:
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
    self.installWindowFrameObservers()
  }

  deinit {
    stopShortcutRecorder()
    unregisterAllRegisteredHotKeys()
    if let eventHandler = hotKeyEventHandler {
      RemoveEventHandler(eventHandler)
      hotKeyEventHandler = nil
    }
    if let observer = trayMenuObserver {
      NotificationCenter.default.removeObserver(observer)
      trayMenuObserver = nil
    }
    if let observer = windowDidMoveObserver {
      NotificationCenter.default.removeObserver(observer)
      windowDidMoveObserver = nil
    }
    if let observer = windowDidResizeObserver {
      NotificationCenter.default.removeObserver(observer)
      windowDidResizeObserver = nil
    }
  }

  // Borderless windows return false by default — override so we receive keyboard events
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }

  private func patchTrayMenuShortcuts(_ menu: NSMenu) {
    for item in menu.items {
      if let shortcut = trayShortcuts[item.title] {
        item.keyEquivalent = shortcut.equiv
        item.keyEquivalentModifierMask = shortcut.mask
      } else {
        item.keyEquivalent = ""
        item.keyEquivalentModifierMask = []
      }
      if let submenu = item.submenu {
        patchTrayMenuShortcuts(submenu)
      }
    }
  }

  private func shortcutModifierMask(from modifiers: [String]) -> NSEvent.ModifierFlags {
    var mask: NSEvent.ModifierFlags = []
    for modifier in modifiers {
      switch modifier {
      case "command":
        mask.insert(.command)
      case "shift":
        mask.insert(.shift)
      case "option":
        mask.insert(.option)
      case "control":
        mask.insert(.control)
      case "function":
        mask.insert(.function)
      case "capsLock":
        mask.insert(.capsLock)
      default:
        break
      }
    }
    return mask
  }

  // Allow window to span multiple displays during overlay mode.
  // macOS constrains windows to a single screen by default; bypass that for the overlay.
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    if overlayScreenFrame != nil {
      MainFlutterWindow.log("constrainFrameRect BYPASSED: \(NSStringFromRect(frameRect))")
      return frameRect
    }
    let constrained = super.constrainFrameRect(frameRect, to: screen)
    if constrained != frameRect {
      MainFlutterWindow.log(
        "constrainFrameRect CONSTRAINED: \(NSStringFromRect(frameRect)) -> \(NSStringFromRect(constrained))"
      )
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

  /// Poll visible window rects on a timer for instant capture startup.
  /// When [includeAxChildren] is false, skips the AX tree walk to avoid
  /// background accessibility churn.
  private func startRectPolling(includeAxChildren: Bool) {
    stopRectPolling()
    let timer = DispatchSource.makeTimerSource(queue: rectPollingQueue)
    // First poll fires immediately, then every 2 seconds.
    // If the AX walk takes ~1s, this leaves a ~1s idle gap between polls.
    timer.schedule(deadline: .now(), repeating: 2.0, leeway: .milliseconds(500))
    timer.setEventHandler { [weak self] in
      let rects = MainFlutterWindow.computeWindowRects(
        promptForAccess: false,
        includeAxChildren: includeAxChildren
      )
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

  /// Compute visible window rects, optionally including AX sub-element rects.
  /// Thread-safe — callable from any queue.
  /// When [promptForAccess] is true, shows the Accessibility permission dialog if not trusted.
  /// When false (used by background polling), silently skips the AX walk if not trusted.
  private static func computeWindowRects(
    promptForAccess: Bool,
    includeAxChildren: Bool = true
  ) -> [[String: Double]] {
    let ownPID = ProcessInfo.processInfo.processIdentifier
    let axTrusted: Bool
    if includeAxChildren {
      if promptForAccess {
        axTrusted = AXIsProcessTrustedWithOptions(
          [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        )
      } else {
        axTrusted = AXIsProcessTrusted()
      }
    } else {
      axTrusted = false
    }

    guard
      let infoList = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
      ) as? [[String: Any]]
    else { return [] }

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
      if includeAxChildren && axTrusted && !walkedPIDs.contains(pid) {
        walkedPIDs.insert(pid)
        let appElement = AXUIElementCreateApplication(pid)
        var axWindows: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &axWindows)
          == .success,
          let windowArray = axWindows as? [AXUIElement]
        {
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
    guard
      AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue)
        == .success,
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
    guard
      AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue)
        == .success,
      let children = childrenValue as? [AXUIElement]
    else { return }

    for child in children {
      if rects.count >= maxTotal { return }
      if let frame = frameOfElement(child),
        frame.size.width >= 10, frame.size.height >= 10
      {
        rects.append([
          "x": Double(frame.origin.x),
          "y": Double(frame.origin.y),
          "width": Double(frame.size.width),
          "height": Double(frame.size.height),
        ])
      }
      collectChildRects(
        element: child, rects: &rects, depth: depth + 1, maxDepth: maxDepth, maxTotal: maxTotal)
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
    guard
      AXUIElementCopyAttributeValue(
        element, kAXChildrenAttribute as CFString, &childrenValue
      ) == .success, let children = childrenValue as? [AXUIElement]
    else { return }

    for child in children {
      guard let frame = frameOfElement(child),
        frame.width >= 10, frame.height >= 10,
        frame.contains(point)
      else { continue }

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
    self.hideToolbarPanel()
    // Remove scroll stop button panel
    self.scrollStopPanel?.close()
    self.scrollStopPanel = nil
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

  // MARK: - Floating toolbar panel

  @objc private func toolbarButtonPressed(_ sender: NSButton) {
    guard let action = sender.identifier?.rawValue else { return }
    self.flutterChannel?.invokeMethod("onToolbarAction", arguments: ["action": action])
    // Keep keyboard focus on the main window after toolbar interactions.
    self.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  private func makeToolbarButton(
    id: String,
    symbol: String,
    toolTip: String,
    destructive: Bool = false
  ) -> NSButton {
    let button = ToolbarButton(title: "", target: self, action: #selector(toolbarButtonPressed(_:)))
    button.identifier = NSUserInterfaceItemIdentifier(id)
    button.isBordered = false
    button.bezelStyle = .regularSquare
    button.focusRingType = .none
    button.toolTip = toolTip
    if #available(macOS 11.0, *) {
      if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip) {
        button.image = image
        button.imageScaling = .scaleProportionallyDown
      } else {
        button.title = String(toolTip.prefix(1))
        button.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
      }
    } else {
      button.title = String(toolTip.prefix(1))
      button.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
    }
    button.contentTintColor =
      destructive ? NSColor.systemRed.withAlphaComponent(0.9) : NSColor.white
    button.wantsLayer = true
    button.layer?.cornerRadius = 11
    button.layer?.masksToBounds = true
    button.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      button.widthAnchor.constraint(equalToConstant: 22),
      button.heightAnchor.constraint(equalToConstant: 22),
    ])
    return button
  }

  private func styleToolbarButton(
    _ button: NSButton,
    isEnabled: Bool,
    isActive: Bool = false,
    destructive: Bool = false
  ) {
    button.isEnabled = isEnabled
    if destructive {
      button.contentTintColor = NSColor.systemRed.withAlphaComponent(isEnabled ? 0.85 : 0.35)
    } else {
      button.contentTintColor = NSColor.white.withAlphaComponent(isEnabled ? 1.0 : 0.35)
    }
    button.layer?.backgroundColor =
      isActive
      ? NSColor.white.withAlphaComponent(0.14).cgColor
      : NSColor.clear.cgColor
    if !isEnabled, let toolbarButton = button as? ToolbarButton {
      toolbarButton.hideTooltipIfVisible()
    }
    button.window?.invalidateCursorRects(for: button)
  }

  private func makeToolbarSeparator() -> NSView {
    let view = NSView()
    view.wantsLayer = true
    view.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.22).cgColor
    view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      view.widthAnchor.constraint(equalToConstant: 1),
      view.heightAnchor.constraint(equalToConstant: 18),
    ])
    return view
  }

  private func localTopLeftRectToScreenRect(x: Double, y: Double, width: Double, height: Double)
    -> NSRect
  {
    let windowFrame = self.frame
    let macX = windowFrame.minX + x
    let macY = windowFrame.maxY - y - height
    return NSRect(x: macX, y: macY, width: width, height: height)
  }

  private func clampToolbarRectToVisibleScreen(_ rect: NSRect) -> NSRect {
    let allScreens = NSScreen.screens
    guard !allScreens.isEmpty else { return rect }

    let parentMid = NSPoint(x: self.frame.midX, y: self.frame.midY)
    let screen =
      allScreens.first(where: { $0.frame.contains(parentMid) }) ?? self.screen ?? NSScreen.main
    guard let visible = screen?.visibleFrame else { return rect }

    let margin: CGFloat = 8
    let minX = visible.minX + margin
    let maxX = visible.maxX - rect.width - margin
    let minY = visible.minY + margin
    let maxY = visible.maxY - rect.height - margin

    let x: CGFloat
    if maxX >= minX {
      x = min(max(rect.minX, minX), maxX)
    } else {
      x = visible.midX - rect.width / 2
    }

    let y: CGFloat
    if maxY >= minY {
      y = min(max(rect.minY, minY), maxY)
    } else {
      y = visible.minY + margin
    }

    return NSRect(x: x, y: y, width: rect.width, height: rect.height)
  }

  private func showOrUpdateToolbarPanel(_ args: [String: Any]) {
    self.adoptToolbarSessionIfNeeded(args)

    let requestId =
      (args["requestId"] as? NSNumber)?.intValue ?? (args["requestId"] as? Int) ?? 0
    if requestId < self.latestToolbarRequestId {
      MainFlutterWindow.log(
        "drop stale toolbar update: requestId=\(requestId) latest=\(self.latestToolbarRequestId)")
      return
    }
    self.latestToolbarRequestId = requestId

    // During transitions (for example pin -> edit), the Flutter window can
    // emit toolbar updates while hidden or fully transparent. Rendering the
    // toolbar in those intermediate states causes visible jumps/flashes.
    guard self.isVisible, self.alphaValue > 0.99 else {
      MainFlutterWindow.log(
        "defer toolbar update: requestId=\(requestId) isVisible=\(self.isVisible) alpha=\(self.alphaValue)"
      )
      self.pendingToolbarArgs = args
      // Internal transition hide: keep last args for stale-update filtering.
      self.hideToolbarPanel(clearPending: false, clearLastArgs: false)
      return
    }
    self.pendingToolbarArgs = nil

    guard let x = args["x"] as? Double,
      let y = args["y"] as? Double,
      let width = args["width"] as? Double,
      let height = args["height"] as? Double,
      let showPin = args["showPin"] as? Bool,
      let showHistoryControls = args["showHistoryControls"] as? Bool,
      let canUndo = args["canUndo"] as? Bool,
      let canRedo = args["canRedo"] as? Bool
    else {
      return
    }
    guard width > 0, height > 0 else { return }
    let activeTool = args["activeTool"] as? String
    let anchorToWindow = args["anchorToWindow"] as? Bool ?? false

    let previousAnchorToWindow = self.lastToolbarArgs?["anchorToWindow"] as? Bool ?? false

    // In preview mode we always use anchorToWindow=true.
    // Ignore stale non-anchored updates that may arrive after transitions or
    // drag-end notifications from prior overlay states.
    if !anchorToWindow,
      self.overlayScreenFrame == nil,
      previousAnchorToWindow
    {
      MainFlutterWindow.log("ignore stale NON-anchorToWindow update in preview")
      return
    }

    self.lastToolbarArgs = args

    let (contentView, targetSize) = makeToolbarPanelContent(
      fallbackHeight: CGFloat(height),
      showPin: showPin,
      showHistoryControls: showHistoryControls,
      canUndo: canUndo,
      canRedo: canRedo,
      activeTool: activeTool
    )

    var screenRect: NSRect
    if anchorToWindow {
      // Preview mode: position toolbar directly below the preview window,
      // ignoring the y value from Flutter (which may be stale after resize).
      // Use a fixed gap of 8pt below the window.
      let toolbarGap: CGFloat = 8.0
      MainFlutterWindow.log(
        "anchorToWindow: self.frame=\(self.frame), isVisible=\(self.isVisible), alpha=\(self.alphaValue)"
      )
      screenRect = NSRect(
        x: self.frame.midX - targetSize.width / 2,
        y: self.frame.minY - toolbarGap - targetSize.height,
        width: targetSize.width,
        height: targetSize.height
      )
      MainFlutterWindow.log("anchorToWindow: computed screenRect=\(screenRect)")
      // Keep the toolbar inside the visible screen bounds.
      screenRect = clampToolbarRectToVisibleScreen(screenRect)
      MainFlutterWindow.log("anchorToWindow: after clamp screenRect=\(screenRect)")
    } else {
      let requestedRect = localTopLeftRectToScreenRect(x: x, y: y, width: width, height: height)
      let requestedCenterX = requestedRect.midX
      let requestedTopY = requestedRect.maxY
      screenRect = NSRect(
        x: requestedCenterX - targetSize.width / 2,
        y: requestedTopY - targetSize.height,
        width: targetSize.width,
        height: targetSize.height
      )
      // Preserve horizontal alignment with selection center as much as
      // possible while keeping the toolbar on-screen.
      screenRect = clampToolbarRectToVisibleScreen(screenRect)
      MainFlutterWindow.log("NON-anchorToWindow: x=\(x), y=\(y), screenRect=\(screenRect)")
    }

    let panel: NSPanel
    if let existing = self.toolbarPanel {
      panel = existing
    } else {
      panel = ToolbarPanel(
        contentRect: screenRect,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
      )
      panel.isFloatingPanel = true
      panel.becomesKeyOnlyIfNeeded = true
      panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 3)
      panel.isOpaque = false
      panel.backgroundColor = .clear
      panel.hasShadow = true
      panel.hidesOnDeactivate = false
      panel.ignoresMouseEvents = false
      panel.acceptsMouseMovedEvents = true
      panel.allowsToolTipsWhenApplicationIsInactive = true
      // NSWindow asserts on invalid combinations: canJoinAllSpaces +
      // moveToActiveSpace cannot be set together.
      panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
      self.toolbarPanel = panel
    }

    MainFlutterWindow.log(
      "setFrame toolbar panel to: \(screenRect), panel.frame before: \(panel.frame)")
    panel.setFrame(screenRect, display: true)
    // Keep toolbar above the active main window level.
    panel.level = NSWindow.Level(rawValue: self.level.rawValue + 1)
    MainFlutterWindow.log("setFrame toolbar panel done, panel.frame after: \(panel.frame)")
    contentView.frame = NSRect(x: 0, y: 0, width: targetSize.width, height: targetSize.height)
    panel.contentView = contentView

    // Keep the toolbar as an independent floating panel.
    // Child-window attachment can apply AppKit-relative positioning rules
    // that fight our explicit setFrame() updates at drag-end.
    if panel.parent != nil {
      panel.parent?.removeChildWindow(panel)
    }
    MainFlutterWindow.log("orderFront: panel.frame=\(panel.frame)")
    panel.orderFront(nil)
  }

  private func refreshToolbarPanelIfNeeded() {
    guard self.isVisible, self.alphaValue > 0.99 else { return }
    guard self.pendingToolbarArgs == nil else { return }
    guard var args = self.lastToolbarArgs else { return }
    let nextRequestId = self.latestToolbarRequestId + 1
    self.latestToolbarRequestId = nextRequestId
    args["requestId"] = nextRequestId
    self.showOrUpdateToolbarPanel(args)
  }

  private func scheduleToolbarFollowRefresh() {
    refreshToolbarPanelIfNeeded()
    toolbarMoveRefreshWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      self?.refreshToolbarPanelIfNeeded()
    }
    toolbarMoveRefreshWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: workItem)
  }

  private func installWindowFrameObservers() {
    if let observer = windowDidMoveObserver {
      NotificationCenter.default.removeObserver(observer)
      windowDidMoveObserver = nil
    }
    if let observer = windowDidResizeObserver {
      NotificationCenter.default.removeObserver(observer)
      windowDidResizeObserver = nil
    }

    windowDidMoveObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didMoveNotification,
      object: self,
      queue: .main
    ) { [weak self] _ in
      self?.scheduleToolbarFollowRefresh()
    }

    windowDidResizeObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didResizeNotification,
      object: self,
      queue: .main
    ) { [weak self] _ in
      self?.refreshToolbarPanelIfNeeded()
    }
  }

  private func makeToolbarPanelContent(
    fallbackHeight: CGFloat,
    showPin: Bool,
    showHistoryControls: Bool,
    canUndo: Bool,
    canRedo: Bool,
    activeTool: String?
  ) -> (ToolbarRootView, NSSize) {
    for button in self.toolbarButtons.values {
      if let toolbarButton = button as? ToolbarButton {
        toolbarButton.hideTooltipIfVisible()
      }
    }
    self.toolbarButtons.removeAll()

    let stack = NSStackView()
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.distribution = .fill
    stack.spacing = 4
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.setContentHuggingPriority(.required, for: .horizontal)
    stack.setContentCompressionResistancePriority(.required, for: .horizontal)

    func addButton(
      id: String,
      symbol: String,
      tip: String,
      enabled: Bool = true,
      active: Bool = false,
      destructive: Bool = false
    ) {
      let button = makeToolbarButton(id: id, symbol: symbol, toolTip: tip, destructive: destructive)
      styleToolbarButton(button, isEnabled: enabled, isActive: active, destructive: destructive)
      self.toolbarButtons[id] = button
      stack.addArrangedSubview(button)
    }

    let tools: [(String, String, String)] = [
      ("rectangle", "rectangle", "Rectangle"),
      ("ellipse", "circle", "Ellipse"),
      ("arrow", "arrow.right", "Arrow"),
      ("line", "minus", "Line"),
      ("pencil", "pencil", "Pencil"),
      ("marker", "paintbrush", "Marker"),
      ("mosaic", "square.grid.3x3", "Mosaic"),
      ("number", "1.circle", "Number"),
      ("text", "textformat.size", "Text"),
    ]
    for (id, symbol, tip) in tools {
      addButton(
        id: id,
        symbol: symbol,
        tip: tip,
        enabled: true,
        active: activeTool == id
      )
    }

    if showHistoryControls {
      stack.addArrangedSubview(makeToolbarSeparator())
      addButton(id: "undo", symbol: "arrow.uturn.backward", tip: "Undo", enabled: canUndo)
      addButton(id: "redo", symbol: "arrow.uturn.forward", tip: "Redo", enabled: canRedo)
    }

    stack.addArrangedSubview(makeToolbarSeparator())
    addButton(id: "copy", symbol: "doc.on.doc", tip: "Copy")
    addButton(id: "save", symbol: "square.and.arrow.down", tip: "Save")
    if showPin {
      addButton(id: "pin", symbol: "pin.fill", tip: "Pin")
    }
    addButton(id: "close", symbol: "xmark", tip: "Close", destructive: true)

    let fittedWidth = ceil(stack.fittingSize.width + 16)
    let targetSize = NSSize(width: fittedWidth, height: fallbackHeight)
    let root = ToolbarRootView(
      frame: NSRect(x: 0, y: 0, width: targetSize.width, height: targetSize.height)
    )
    root.wantsLayer = true
    root.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.88).cgColor
    root.layer?.cornerRadius = fallbackHeight / 2
    root.layer?.masksToBounds = true

    root.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
      stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
      stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 4),
      stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -4),
    ])

    root.layoutSubtreeIfNeeded()
    return (root, targetSize)
  }

  private func hideToolbarPanel(
    clearPending: Bool = true,
    clearLastArgs: Bool = true,
    minRequestId: Int? = nil
  ) {
    if let minRequestId = minRequestId, minRequestId > self.latestToolbarRequestId {
      self.latestToolbarRequestId = minRequestId
    }
    if clearPending {
      pendingToolbarArgs = nil
    }
    if clearLastArgs {
      lastToolbarArgs = nil
    }
    for button in self.toolbarButtons.values {
      if let toolbarButton = button as? ToolbarButton {
        toolbarButton.hideTooltipIfVisible()
      }
    }
    guard let panel = self.toolbarPanel else { return }
    if let parent = panel.parent {
      parent.removeChildWindow(panel)
    }
    panel.orderOut(nil)
  }

  private func resetToolbarTrackingState(sessionId: Int64?) {
    self.latestToolbarSessionId = sessionId
    self.latestToolbarRequestId = 0
    self.pendingToolbarArgs = nil
    self.lastToolbarArgs = nil
    self.toolbarMoveRefreshWorkItem?.cancel()
    self.toolbarMoveRefreshWorkItem = nil
  }

  private func resetToolbarPanelState() {
    self.resetToolbarTrackingState(sessionId: nil)
    self.hideToolbarPanel(clearPending: true, clearLastArgs: true)
    MainFlutterWindow.log("resetToolbarPanelState")
  }

  private func adoptToolbarSessionIfNeeded(_ args: [String: Any]) {
    guard let sessionValue = args["sessionId"] as? NSNumber else { return }
    let sessionId = sessionValue.int64Value
    if self.latestToolbarSessionId == sessionId { return }

    self.resetToolbarTrackingState(sessionId: sessionId)
    self.hideToolbarPanel(clearPending: true, clearLastArgs: true)
    MainFlutterWindow.log("toolbar session switched: \(sessionId)")
  }

  // MARK: - Overlay helpers

  /// Find the target screen from arguments (CG origin) or mouse location,
  /// then configure + show the overlay window on that screen in one shot.
  /// Used for the initial ⌘⇧2 capture.
  private func configureOverlay(_ args: [String: Double]?) {
    let allScreens = NSScreen.screens
    guard !allScreens.isEmpty else { return }

    func cgOrigin(for screen: NSScreen) -> (x: Double, y: Double)? {
      guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
      else {
        return nil
      }
      let bounds = CGDisplayBounds(id.uint32Value)
      return (Double(bounds.origin.x), Double(bounds.origin.y))
    }

    let targetScreen: NSScreen
    if let args = args,
      let targetCGX = args["screenOriginX"],
      let targetCGY = args["screenOriginY"]
    {
      targetScreen =
        allScreens.first(where: { screen in
          guard let origin = cgOrigin(for: screen) else { return false }
          return abs(origin.x - targetCGX) < 2 && abs(origin.y - targetCGY) < 2
        }) ?? allScreens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
        ?? NSScreen.main ?? allScreens[0]
      MainFlutterWindow.log("configureOverlay: matched by CG origin (\(targetCGX),\(targetCGY))")
    } else {
      let mouseLocation = NSEvent.mouseLocation
      targetScreen =
        allScreens.first(where: { $0.frame.contains(mouseLocation) })
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
    self.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
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
        screen.frame.contains(mouse)
          && (abs(screen.frame.origin.x - overlayFrame.origin.x) > 2
            || abs(screen.frame.origin.y - overlayFrame.origin.y) > 2
            || abs(screen.frame.width - overlayFrame.width) > 2
            || abs(screen.frame.height - overlayFrame.height) > 2)
      }
      if mouseIsOnDifferentScreen {
        if let monitor = self.displayChangeMonitor {
          NSEvent.removeMonitor(monitor)
          self.displayChangeMonitor = nil
        }
        MainFlutterWindow.log(
          "displayChange: mouse=\(mouse) left overlay=\(NSStringFromRect(overlayFrame))")
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

// MARK: - Toolbar panel views

/// Root view for the floating toolbar panel.
/// Forces arrow cursor over non-button areas so the overlay crosshair doesn't bleed through.
private class ToolbarRootView: NSView {
  private var hoverTrackingArea: NSTrackingArea?

  override func updateTrackingAreas() {
    if let area = hoverTrackingArea {
      removeTrackingArea(area)
    }
    hoverTrackingArea = NSTrackingArea(
      rect: bounds,
      options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate],
      owner: self,
      userInfo: nil
    )
    if let area = hoverTrackingArea {
      addTrackingArea(area)
    }
    super.updateTrackingAreas()
  }

  override func mouseEntered(with event: NSEvent) {
    NSCursor.arrow.set()
  }

  override func mouseMoved(with event: NSEvent) {
    NSCursor.arrow.set()
  }

  override func cursorUpdate(with event: NSEvent) {
    NSCursor.arrow.set()
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .arrow)
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }
}

/// Toolbar button with explicit pointing-hand cursor.
private class ToolbarButton: NSButton {
  private static weak var visibleTooltipOwner: ToolbarButton?

  private var hoverTrackingArea: NSTrackingArea?
  private var tooltipTimer: Timer?
  private var tooltipPanel: ToolbarTooltipPanel?

  func hideTooltipIfVisible() {
    tooltipTimer?.invalidate()
    tooltipTimer = nil
    if let panel = tooltipPanel {
      if let parent = panel.parent {
        parent.removeChildWindow(panel)
      }
      panel.orderOut(nil)
    }
    if ToolbarButton.visibleTooltipOwner === self {
      ToolbarButton.visibleTooltipOwner = nil
    }
  }

  private func scheduleTooltip() {
    tooltipTimer?.invalidate()
    tooltipTimer = nil

    guard isEnabled, let tip = toolTip, !tip.isEmpty else { return }
    tooltipTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
      self?.showTooltipNow()
    }
  }

  private func showTooltipNow() {
    guard isEnabled,
      let tip = toolTip,
      !tip.isEmpty,
      let window = self.window
    else {
      return
    }

    if let other = ToolbarButton.visibleTooltipOwner, other !== self {
      other.hideTooltipIfVisible()
    }
    ToolbarButton.visibleTooltipOwner = self

    let label = NSTextField(labelWithString: tip)
    label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
    label.textColor = .white
    label.backgroundColor = .clear
    label.alignment = .center
    label.translatesAutoresizingMaskIntoConstraints = false

    let root = NSView()
    root.wantsLayer = true
    root.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.95).cgColor
    root.layer?.cornerRadius = 7
    root.layer?.masksToBounds = true
    root.addSubview(label)

    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
      label.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
      label.topAnchor.constraint(equalTo: root.topAnchor, constant: 4),
      label.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -4),
    ])

    let fitting = root.fittingSize
    let size = NSSize(
      width: max(36, ceil(fitting.width)),
      height: max(20, ceil(fitting.height))
    )

    let panel: ToolbarTooltipPanel
    if let existing = tooltipPanel {
      panel = existing
    } else {
      panel = ToolbarTooltipPanel(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
      )
      panel.isFloatingPanel = true
      panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 3)
      panel.isOpaque = false
      panel.backgroundColor = .clear
      panel.hasShadow = true
      panel.hidesOnDeactivate = false
      panel.ignoresMouseEvents = true
      panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
      tooltipPanel = panel
    }
    panel.contentView = root

    let buttonRectInWindow = convert(bounds, to: nil)
    let buttonRectOnScreen = window.convertToScreen(buttonRectInWindow)
    var x = buttonRectOnScreen.midX - size.width / 2
    var y = buttonRectOnScreen.maxY + 8

    if let visible = window.screen?.visibleFrame {
      let inset = visible.insetBy(dx: 8, dy: 8)
      if y + size.height > inset.maxY {
        y = buttonRectOnScreen.minY - size.height - 8
      }
      x = min(max(x, inset.minX), inset.maxX - size.width)
      y = min(max(y, inset.minY), inset.maxY - size.height)
    }

    panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    if panel.parent !== window {
      if let oldParent = panel.parent {
        oldParent.removeChildWindow(panel)
      }
      window.addChildWindow(panel, ordered: .above)
    }
    panel.orderFront(nil)
  }

  override func updateTrackingAreas() {
    if let area = hoverTrackingArea {
      removeTrackingArea(area)
    }
    hoverTrackingArea = NSTrackingArea(
      rect: bounds,
      options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate],
      owner: self,
      userInfo: nil
    )
    if let area = hoverTrackingArea {
      addTrackingArea(area)
    }
    super.updateTrackingAreas()
  }

  override func mouseEntered(with event: NSEvent) {
    NSCursor.pointingHand.set()
    scheduleTooltip()
  }

  override func mouseMoved(with event: NSEvent) {
    NSCursor.pointingHand.set()
  }

  override func mouseExited(with event: NSEvent) {
    NSCursor.arrow.set()
    hideTooltipIfVisible()
  }

  override func cursorUpdate(with event: NSEvent) {
    if isEnabled {
      NSCursor.pointingHand.set()
      scheduleTooltip()
    } else {
      NSCursor.arrow.set()
      hideTooltipIfVisible()
    }
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: isEnabled ? .pointingHand : .arrow)
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }

  override func mouseDown(with event: NSEvent) {
    hideTooltipIfVisible()
    super.mouseDown(with: event)
  }
}

/// Borderless floating panel for toolbar controls.
/// Uses a normal (activatable) panel so AppKit hover/cursor/tooltip behavior works.
private class ToolbarPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

/// Borderless tooltip panel for toolbar button hover labels.
private class ToolbarTooltipPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

// MARK: - PinnedImagePanel

/// Floating panel that displays a pinned screenshot as a sticker.
/// Supports drag-to-move, Space to edit, Escape to close.
private class PinnedImagePanel: NSPanel {
  var onEdit: (() -> Void)?
  var onClose: (() -> Void)?
  private var didNotifyClose = false

  override var canBecomeKey: Bool { true }

  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 49:  // Space → edit
      onEdit?()
    case 53:  // Escape → close
      self.close()
    default:
      break  // Suppress system beep for all keys.
    }
  }

  override func close() {
    let shouldNotify = !didNotifyClose
    didNotifyClose = true
    super.close()
    if shouldNotify {
      onClose?()
    }
  }
}

// MARK: - PinnedImageView

/// NSView that draws a pinned image scaled to fit its bounds while preserving aspect ratio.
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

    // Calculate destination rect that preserves aspect ratio (BoxFit.contain behavior).
    let imageSize = image.size
    let boundsSize = bounds.size

    guard imageSize.width > 0, imageSize.height > 0, boundsSize.width > 0, boundsSize.height > 0
    else {
      image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1.0)
      return
    }

    let imageAspect = imageSize.width / imageSize.height
    let boundsAspect = boundsSize.width / boundsSize.height

    let destRect: NSRect
    if imageAspect > boundsAspect {
      // Image is wider relative to its height - fit to width
      let width = boundsSize.width
      let height = width / imageAspect
      let x: CGFloat = 0
      let y = (boundsSize.height - height) / 2
      destRect = NSRect(x: x, y: y, width: width, height: height)
    } else {
      // Image is taller relative to its width - fit to height
      let height = boundsSize.height
      let width = height * imageAspect
      let x = (boundsSize.width - width) / 2
      let y: CGFloat = 0
      destRect = NSRect(x: x, y: y, width: width, height: height)
    }

    image.draw(
      in: destRect, from: NSRect(origin: .zero, size: imageSize), operation: .copy, fraction: 1.0)
  }
}
