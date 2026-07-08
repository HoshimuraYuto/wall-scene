import AVFoundation
import AppKit

// The v1 integrated controller. Implements AppActionsV2 and oversees:
// - Reading/writing the config (AppConfig) and reconciling it against the connected displays
//   (reconcileAll)
// - Starting, stopping, and replacing the per-display runtime controllers
//   (SingleVideoController / FolderSpaceCoordinator)
// - Following screen-configuration changes and power-saving state changes
@MainActor
final class AppControllerV2: AppActionsV2 {
  /// Runtime controller for one display. For standard (not controlled) there is no entry at all
  private enum RuntimeController {
    case single(SingleVideoController)
    case folder(FolderSpaceCoordinator)
  }

  /// A pair of a runtime controller and the (validated) DisplayMode it was created from.
  /// By comparing against this `mode` on every reconcile, rather than against the DisplayMode
  /// in the config, the replacement decision incorporates the validation result that
  /// "empty or nonexistent paths are treated as unset".
  private struct RuntimeEntry {
    var mode: DisplayMode
    var controller: RuntimeController
  }

  private let state: AppStateV2

  private let configStore: ConfigStoring
  private let bindingStore: SpaceBindingStore
  private let mediaLibrary: MediaLibraryScanning
  private let beaconManager: BeaconManaging
  private let playback: PlaybackControlling
  private let windowFactory: WallpaperWindowFactory
  private let powerMonitor: PowerMonitor
  private let loginItemManager: LoginItemManager
  private let externalChangePrompter: ExternalChangePrompting

  private var settingsWindow: SettingsWindowControllerV2?

  /// The moment this app process launched (AppControllerV2 is constructed exactly once per
  /// process, in AppDelegate, so its own init is an adequate proxy for process launch time).
  /// Passed unchanged to every FolderSpaceCoordinator this controller ever constructs (see
  /// reconcileDisplay below), including ones recreated later in the same run (scaling/timing
  /// change, display reconnect, etc.), so that a coordinator's .onLogin epoch reset only ever
  /// fires for an actual app launch — not for every recreation (see FolderSpaceCoordinator's
  /// appLaunchTime doc comment for the full rationale)
  private let appLaunchTime = Date()

  /// key = displayUUID
  private var runtimeControllers: [String: RuntimeEntry] = [:]

  private var screenParamsObserver: NSObjectProtocol?

  init(state: AppStateV2) {
    self.state = state

    self.configStore = ConfigStore()
    self.bindingStore = SpaceBindingStore()
    self.mediaLibrary = MediaLibrary()
    self.beaconManager = BeaconManager(beaconsDir: Paths.beaconsDir)
    self.playback = PlaybackEngine()
    self.windowFactory = WallpaperWindowControllerFactory()
    self.powerMonitor = PowerMonitor()
    self.loginItemManager = LoginItemManager()
    self.externalChangePrompter = NSAlertExternalChangePrompter()

    // Reflect the list of "unmanaged" spaces (P0-2) into state whenever the bindingStore
    // changes. Because FolderSpaceCoordinator updates the bindingStore directly (without going
    // through AppControllerV2), this callback is the only way to detect the change
    self.bindingStore.onChange = { [weak self] in self?.refreshUnmanagedState() }
  }

  /// Kicks off the entire startup sequence
  func start() {
    Task { @MainActor [weak self] in
      await self?.bootstrap()
    }
  }

  private func bootstrap() async {
    do {
      state.config = try await configStore.load()
    } catch {
      state.lastError = String(localized: "Failed to load settings: \(error.localizedDescription)")
      Log.error("appControllerV2", "config load failed: \(error.localizedDescription)")
      state.config = .empty()
    }

    await syncLoginItemState()
    // PlaybackEngine has its own internal PowerMonitor, separate from AppControllerV2's, and
    // autonomously decides folder mode's fallback/restore. Without syncing
    // config.powerSavingEnabled here, turning the feature off would have no effect on folder
    // mode alone (single-video mode is handled entirely through the direct calls via
    // handlePowerStateChange below, so it does not need this sync)
    playback.powerSavingEnabled = state.config.powerSavingEnabled
    reconcileAll()
    refreshUnmanagedState()

    screenParamsObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in self?.reconcileAll() }
    }

    powerMonitor.onChange = { [weak self] constrained in
      self?.handlePowerStateChange(constrained)
    }

    Log.info("appControllerV2", "startup complete")
  }

  /// Syncs config.launchAtLogin treating the actual SMAppService (system-side) state as the
  /// source of truth. Saves if they differ
  private func syncLoginItemState() async {
    let systemEnabled = loginItemManager.isEnabled
    guard state.config.launchAtLogin != systemEnabled else { return }
    Log.info("appControllerV2", "syncing launchAtLogin to the system state: \(systemEnabled)")
    state.config.launchAtLogin = systemEnabled
    do {
      try await configStore.save(state.config)
    } catch {
      state.lastError = String(localized: "Failed to save settings: \(error.localizedDescription)")
      Log.error(
        "appControllerV2", "failed to save launchAtLogin sync: \(error.localizedDescription)")
    }
  }

  // MARK: - reconcile

  /// Reconciles the connected displays against config.displays, composing state.displays while
  /// swapping each display's runtime controller to its desired state
  private func reconcileAll() {
    let screens = NSScreen.screens
    let connectedUUIDs = Set(screens.map(\.stableDisplayUUID))

    var displayInfos: [DisplayInfo] = screens.map { screen in
      DisplayInfo(
        displayUUID: screen.stableDisplayUUID, name: screen.localizedName, isConnected: true)
    }
    for (uuid, config) in state.config.displays where !connectedUUIDs.contains(uuid) {
      displayInfos.append(
        DisplayInfo(displayUUID: uuid, name: config.displayName, isConnected: false))
    }
    state.displays = displayInfos

    for screen in screens {
      reconcileDisplay(uuid: screen.stableDisplayUUID, screen: screen)
    }

    let staleUUIDs = runtimeControllers.keys.filter { !connectedUUIDs.contains($0) }
    for uuid in staleUUIDs {
      guard let entry = runtimeControllers.removeValue(forKey: uuid) else { continue }
      stopController(entry, displayUUID: uuid, reason: "display disconnected")
    }
  }

  /// Validates config.displays[uuid].mode and decides the DisplayMode that should actually run.
  /// Empty or nonexistent paths are treated as "unset" (equivalent to .standard), not as errors
  private func desiredMode(for uuid: String) -> DisplayMode {
    guard let configured = state.config.displays[uuid]?.mode else { return .standard }

    switch configured {
    case .standard:
      return .standard

    case .single(let videoPath, let scaling):
      guard !videoPath.isEmpty, FileManager.default.fileExists(atPath: videoPath) else {
        Log.info(
          "appControllerV2",
          "single mode but the video is unset/missing, not controlling display=\(uuid) path=\(videoPath)"
        )
        return .standard
      }
      return .single(videoPath: videoPath, scaling: scaling)

    case .folder(let folderPath, let timing, let scaling):
      var isDirectory: ObjCBool = false
      let exists =
        !folderPath.isEmpty
        && FileManager.default.fileExists(atPath: folderPath, isDirectory: &isDirectory)
        && isDirectory.boolValue
      guard exists else {
        Log.info(
          "appControllerV2",
          "folder mode but the folder is unset/missing, not controlling display=\(uuid) path=\(folderPath)"
        )
        return .standard
      }
      return .folder(folderPath: folderPath, timing: timing, scaling: scaling)
    }
  }

  /// Reconcile for a single display. Compares the desired mode against the current runtime
  /// controller and replaces it if the contents changed. Does nothing if they are identical
  /// (single video is still made to follow resolution changes)
  private func reconcileDisplay(uuid: String, screen: NSScreen) {
    let desired = desiredMode(for: uuid)
    let current = runtimeControllers[uuid]

    if current?.mode == desired {
      if case .single(let controller) = current?.controller {
        controller.updateFrame()
      }
      return
    }

    if let current {
      stopController(current, displayUUID: uuid, reason: "mode change")
    }

    switch desired {
    case .standard:
      runtimeControllers[uuid] = nil

    case .single(let videoPath, let scaling):
      let controller = SingleVideoController(
        screen: screen,
        videoURL: URL(fileURLWithPath: videoPath),
        scaling: scaling,
        externalChangePolicy: state.config.externalChangePolicy,
        externalChangePrompter: externalChangePrompter
      )
      controller.start()
      runtimeControllers[uuid] = RuntimeEntry(mode: desired, controller: .single(controller))
      Log.info("appControllerV2", "single controller start display=\(uuid) video=\(videoPath)")

    case .folder(let folderPath, let timing, let scaling):
      let coordinator = FolderSpaceCoordinator(
        displayUUID: uuid,
        folderURL: URL(fileURLWithPath: folderPath),
        timing: timing,
        beacon: beaconManager,
        playback: playback,
        windowFactory: windowFactory,
        bindingStore: bindingStore,
        mediaLibrary: mediaLibrary,
        scaling: scaling,
        externalChangePolicy: state.config.externalChangePolicy,
        externalChangePrompter: externalChangePrompter,
        appLaunchTime: appLaunchTime
      )
      coordinator.start()
      runtimeControllers[uuid] = RuntimeEntry(mode: desired, controller: .folder(coordinator))
      Log.info("appControllerV2", "folder controller start display=\(uuid) folder=\(folderPath)")
    }
  }

  private func stopController(_ entry: RuntimeEntry, displayUUID: String, reason: String) {
    switch entry.controller {
    case .single(let controller):
      controller.stop()
      Log.info("appControllerV2", "single controller stop display=\(displayUUID) reason=\(reason)")
    case .folder(let coordinator):
      coordinator.stop()
      Log.info("appControllerV2", "folder controller stop display=\(displayUUID) reason=\(reason)")
    }
  }

  // MARK: - Power saving

  /// PowerMonitor state change. Tells SingleVideoController directly via enter/exitPowerSaving,
  /// and prompts FolderSpaceCoordinator to refresh() (the window creation/reclamation itself is
  /// done by PlaybackEngine's own internal PowerMonitor watching isPowerSaving, so the role here
  /// is "providing the trigger to rebuild windows once the constraint is lifted").
  /// FolderSpaceCoordinator has no onPowerStateChange, so AppControllerV2 is the sole owner of
  /// this wiring.
  ///
  /// PowerMonitor.onChange only fires when the value changes, so the decision of whether we
  /// should actually fall back (constrained && config.powerSavingEnabled) must always go through
  /// applyEffectivePowerSavingState(). That way, toggling via setPowerSavingEnabled reapplies
  /// with the same logic based on the current values
  private func handlePowerStateChange(_ constrained: Bool) {
    Log.info("appControllerV2", "power monitor changed constrained=\(constrained)")
    applyEffectivePowerSavingState()
  }

  /// Computes in one place whether we should actually fall back
  /// (= PowerMonitor.isConstrained && config.powerSavingEnabled) and applies it to the current
  /// runtime controllers whether or not it changed.
  /// Called from both PowerMonitor.onChange (on state transitions) and setPowerSavingEnabled
  /// (on toggle); the single entry point for the fallback/restore logic
  private func applyEffectivePowerSavingState() {
    let effective = powerMonitor.isConstrained && state.config.powerSavingEnabled
    state.isPowerSaving = effective
    Log.info(
      "appControllerV2",
      "power saving state applied effective=\(effective) constrained=\(powerMonitor.isConstrained) enabled=\(state.config.powerSavingEnabled)"
    )
    for entry in runtimeControllers.values {
      switch entry.controller {
      case .single(let controller):
        if effective {
          controller.enterPowerSaving()
        } else {
          controller.exitPowerSaving()
        }
      case .folder(let coordinator):
        coordinator.refresh()
      }
    }
  }

  // MARK: - AppActionsV2

  func updateDisplayMode(displayUUID: String, mode: DisplayMode) {
    Log.info("appControllerV2", "updateDisplayMode display=\(displayUUID) mode=\(mode)")

    let oldMode = state.config.displays[displayUUID]?.mode

    let displayName: String
    if let screen = NSScreen.screens.first(where: { $0.stableDisplayUUID == displayUUID }) {
      displayName = screen.localizedName
    } else {
      displayName = state.config.displays[displayUUID]?.displayName ?? displayUUID
    }

    state.config.displays[displayUUID] = DisplayConfig(
      displayUUID: displayUUID, displayName: displayName, mode: mode)
    persistConfig()

    if let screen = NSScreen.screens.first(where: { $0.stableDisplayUUID == displayUUID }) {
      reconcileDisplay(uuid: displayUUID, screen: screen)

      // When only the folder path changes while staying in folder mode, the bindings in
      // SpaceBindingStore survive the coordinator rebuild, so media from the old folder would
      // keep being shown until the interval expires. To prevent "I changed the folder but the
      // wallpaper didn't change", advance the freshly recreated coordinator's reference time so
      // that every space becomes eligible for reassignment (the currently visible space
      // immediately, the others on their next visit; the same path as .onWake/.onLogin).
      // The trigger condition is limited to .folder→.folder with a folderPath mismatch only:
      // - Firing on a standard/single→folder transition would break the existing design that
      //   deliberately preserves the previous session's assignments (bindings survive a mode
      //   round-trip)
      // - For a scaling-only change, re-rendering the same media via BeaconRegenerationPolicy
      //   is the correct behavior, and reassigning every space for a timing-only change would
      //   be excessive
      if case .folder(let oldPath, _, _)? = oldMode,
        case .folder(let newPath, _, _) = mode,
        URL(fileURLWithPath: oldPath).standardizedFileURL.path
          != URL(fileURLWithPath: newPath).standardizedFileURL.path,
        case .folder(let coordinator) = runtimeControllers[displayUUID]?.controller
      {
        Log.info(
          "appControllerV2",
          "folder path change detected, marking all spaces for reassignment display=\(displayUUID) old=\(oldPath) new=\(newPath)"
        )
        coordinator.reassignNow()
      }
    }
  }

  func reassignNow(displayUUID: String) {
    Log.info("appControllerV2", "manual immediate reassignment requested display=\(displayUUID)")
    // single/standard (or folder that never started due to an empty/missing path) is a no-op
    // (same convention as resetUnmanagedSpaces)
    if case .folder(let coordinator) = runtimeControllers[displayUUID]?.controller {
      coordinator.reassignNow()
    }
  }

  func setGloballyPaused(_ paused: Bool) {
    Log.info("appControllerV2", "setGloballyPaused \(paused)")
    state.config.isGloballyPaused = paused
    persistConfig()

    // Folder mode: all FolderSpaceCoordinators share the same PlaybackEngine, so as in the old
    // AppController, setting isGloballyPaused once is enough to propagate to every window
    playback.isGloballyPaused = paused

    // Single-video mode: self-contained without going through PlaybackEngine, so call
    // pause()/resume() on each individually
    for entry in runtimeControllers.values {
      guard case .single(let controller) = entry.controller else { continue }
      if paused {
        controller.pause()
      } else {
        controller.resume()
      }
    }
  }

  func setPowerSavingEnabled(_ enabled: Bool) {
    Log.info("appControllerV2", "setPowerSavingEnabled \(enabled)")
    state.config.powerSavingEnabled = enabled
    persistConfig()

    // Folder mode: sync to PlaybackEngine's own internal PowerMonitor. As a result, turning it
    // off while in fallback immediately flips isPowerSaving back to false (windows are rebuilt
    // on the next refresh()), and turning it on while currently constrained immediately sets
    // isPowerSaving to true and the windows are reclaimed
    playback.powerSavingEnabled = enabled

    // Reapply single-video mode, state.isPowerSaving, and the trigger for rebuilding
    // folder-mode windows in one shot, based on the current value of AppControllerV2's own
    // PowerMonitor
    applyEffectivePowerSavingState()
  }

  func setExternalChangePolicy(_ policy: ExternalChangePolicy) {
    Log.info("appControllerV2", "setExternalChangePolicy \(policy)")
    state.config.externalChangePolicy = policy
    persistConfig()

    // Unlike scaling/timing etc., externalChangePolicy is applied live without recreating the
    // controllers (same convention as setPowerSavingEnabled)
    for entry in runtimeControllers.values {
      switch entry.controller {
      case .single(let controller):
        controller.externalChangePolicy = policy
      case .folder(let coordinator):
        coordinator.externalChangePolicy = policy
      }
    }
  }

  func resetUnmanagedSpaces(displayUUID: String) {
    Log.info("appControllerV2", "resetUnmanagedSpaces display=\(displayUUID)")
    let unmanaged = bindingStore.bindings(displayUUID: displayUUID).filter { $0.isUnmanaged }
    for binding in unmanaged {
      bindingStore.remove(beaconUUID: binding.beaconUUID)
    }
    guard !unmanaged.isEmpty else { return }

    // After the reset, the next visit to that space treats it as a "new/unvisited space", and
    // the normal folder assignment logic automatically brings it back under management. For the
    // case where the user wants it applied right now, refresh() the display's folder coordinator
    // immediately if one exists
    if case .folder(let coordinator) = runtimeControllers[displayUUID]?.controller {
      coordinator.refresh()
    }
  }

  /// Recomputes the list of "unmanaged" spaces from the bindingStore's current values and
  /// reflects it into state. Called from bindingStore.onChange (at all times) and at bootstrap
  /// (initial application right after startup)
  private func refreshUnmanagedState() {
    state.unmanagedSpaces = Dictionary(
      grouping: bindingStore.bindings.filter { $0.isUnmanaged }, by: { $0.displayUUID })
  }

  func setLaunchAtLogin(_ enabled: Bool) {
    Log.info("appControllerV2", "setLaunchAtLogin \(enabled)")
    do {
      try loginItemManager.setEnabled(enabled)
      state.config.launchAtLogin = enabled
      persistConfig()
    } catch {
      state.lastError = String(
        localized: "Failed to set launch at login: \(error.localizedDescription)")
      Log.error("appControllerV2", "setLaunchAtLogin failed: \(error.localizedDescription)")
    }
  }

  func openSettingsWindow() {
    Log.info("appControllerV2", "openSettingsWindow")
    if settingsWindow == nil {
      settingsWindow = SettingsWindowControllerV2(state: state)
    }
    settingsWindow?.show()
  }

  func quitApp() {
    Log.info("appControllerV2", "quitApp")
    for (uuid, entry) in runtimeControllers {
      stopController(entry, displayUUID: uuid, reason: "quit")
    }
    runtimeControllers.removeAll()
    playback.stopAll()
    NSApp.terminate(nil)
  }

  private func persistConfig() {
    let config = state.config
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await self.configStore.save(config)
      } catch {
        self.state.lastError = String(
          localized: "Failed to save settings: \(error.localizedDescription)")
        Log.error("appControllerV2", "config save failed: \(error.localizedDescription)")
      }
    }
  }

  // MARK: - Debug (for the parent agent's on-device E2E)

  /// Dump of displayUUID → runtime controller kind ("single" / "folder").
  /// standard / never-started displays are not included
  func debugRuntimeControllerKinds() -> [String: String] {
    runtimeControllers.mapValues { entry in
      switch entry.controller {
      case .single: return "single"
      case .folder: return "folder"
      }
    }
  }
}
