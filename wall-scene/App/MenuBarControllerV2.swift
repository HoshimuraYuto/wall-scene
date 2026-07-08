import AppKit
import Combine

/// Manages the v1 menu bar NSStatusItem and its menu.
@MainActor
final class MenuBarControllerV2: NSObject {
  private let state: AppStateV2
  private let statusItem: NSStatusItem
  private var cancellable: AnyCancellable?

  init(state: AppStateV2) {
    self.state = state
    self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    super.init()

    if let button = statusItem.button {
      if let image = NSImage(systemSymbolName: "play.tv", accessibilityDescription: "Wall Scene") {
        button.image = image
      } else {
        button.title = "SL"
      }
    }

    rebuildMenu()

    cancellable = state.objectWillChange
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.rebuildMenu()
      }
  }

  private func rebuildMenu() {
    let menu = NSMenu()

    menu.addItem(
      makeItem(title: String(localized: "Open Settings…"), action: #selector(openSettings)))

    menu.addItem(.separator())

    let pauseItem = makeItem(
      title: String(localized: "Pause Playback"), action: #selector(togglePause))
    pauseItem.state = state.config.isGloballyPaused ? .on : .off
    menu.addItem(pauseItem)

    menu.addItem(.separator())

    menu.addItem(makeItem(title: String(localized: "Quit Wall Scene"), action: #selector(quit)))

    statusItem.menu = menu
  }

  private func makeItem(title: String, action: Selector) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    return item
  }

  @objc private func openSettings() {
    state.actions?.openSettingsWindow()
  }

  @objc private func togglePause() {
    state.actions?.setGloballyPaused(!state.config.isGloballyPaused)
  }

  @objc private func quit() {
    state.actions?.quitApp()
  }
}
