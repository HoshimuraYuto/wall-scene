import AppKit
import SwiftUI

/// Controller that owns and presents the v1 settings window.
/// Reuses the NSWindow created once: closing it does not destroy it, so a later show() can
/// bring it back.
@MainActor
final class SettingsWindowControllerV2: NSObject, NSWindowDelegate {
  private let window: NSWindow
  private var didCenterOnce = false

  init(state: AppStateV2) {
    let rootView = SettingsViewV2(state: state)
    let hostingController = NSHostingController(rootView: rootView)

    let window = NSWindow(contentViewController: hostingController)
    window.title = String(localized: "Wall Scene Settings")
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
    window.setContentSize(NSSize(width: 680, height: 620))
    window.contentMinSize = NSSize(width: 560, height: 480)
    window.isReleasedWhenClosed = false
    self.window = window

    super.init()
    window.delegate = self
  }

  /// Brings the window to the front. Centers it on screen only the first time.
  func show() {
    NSApp.activate(ignoringOtherApps: true)
    if !didCenterOnce {
      window.center()
      didCenterOnce = true
    }
    window.makeKeyAndOrderFront(nil)
  }
}
