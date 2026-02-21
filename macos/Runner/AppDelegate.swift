import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // Keep running when window is hidden — we're a tray app
    return false
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    // Run as accessory app: no Dock icon, no main menu bar presence
    NSApp.setActivationPolicy(.accessory)
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
