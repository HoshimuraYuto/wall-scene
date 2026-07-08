import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var state: AppStateV2!
  private var controller: AppControllerV2!
  private var menuBar: MenuBarControllerV2!

  func applicationDidFinishLaunching(_ notification: Notification) {
    Paths.ensureDirectories()
    Log.info("app", "Wall Scene launched")

    let state = AppStateV2()
    let controller = AppControllerV2(state: state)
    state.actions = controller
    controller.start()

    self.state = state
    self.controller = controller
    self.menuBar = MenuBarControllerV2(state: state)

    setupDebugFlags()
  }

  /// Headless verification flags used by the parent agent for on-device E2E testing
  /// (v1: targets AppControllerV2 / AppStateV2)
  private func setupDebugFlags() {
    let arguments = CommandLine.arguments

    if let index = arguments.firstIndex(of: "--debug-set-single"), index + 1 < arguments.count {
      let path = arguments[index + 1]
      Log.info("debug", "--debug-set-single scheduled path=\(path)")
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
        self?.applyDebugMode(
          .single(videoPath: path, scaling: .fill), flagName: "--debug-set-single")
      }
    }

    if let index = arguments.firstIndex(of: "--debug-set-folder"), index + 1 < arguments.count {
      let path = arguments[index + 1]
      Log.info("debug", "--debug-set-folder scheduled path=\(path)")
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
        self?.applyDebugMode(
          .folder(folderPath: path, timing: .interval(minutes: 5), scaling: .fill),
          flagName: "--debug-set-folder")
      }
    }

    if arguments.contains("--debug-status") {
      for i in 0...2 {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0 + Double(i) * 5.0) { [weak self] in
          self?.logDebugStatus()
        }
      }
    }

    if arguments.contains("--debug-open-settings") {
      Log.info("debug", "--debug-open-settings scheduled")
      DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
        Log.info("debug", "--debug-open-settings executing")
        self?.state.actions?.openSettingsWindow()
      }
    }
  }

  /// Applies the given mode to the main display (frame.origin == (0, 0))
  @MainActor
  private func applyDebugMode(_ mode: DisplayMode, flagName: String) {
    guard let mainScreen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) else {
      Log.warn("debug", "\(flagName) execution failed: main display not found")
      return
    }
    let uuid = mainScreen.stableDisplayUUID
    Log.info("debug", "\(flagName) executing display=\(uuid) mode=\(mode)")
    state.actions?.updateDisplayMode(displayUUID: uuid, mode: mode)
  }

  @MainActor
  private func logDebugStatus() {
    let kinds = controller.debugRuntimeControllerKinds()
    let displaysDump = state.config.displays.map { uuid, config -> String in
      "\(config.displayName)(\(uuid))=\(config.mode) controller=\(kinds[uuid] ?? "none")"
    }.joined(separator: ", ")
    Log.info(
      "debug",
      "status displays=[\(displaysDump)] "
        + "isPowerSaving=\(state.isPowerSaving) isGloballyPaused=\(state.config.isGloballyPaused)"
    )
  }
}
