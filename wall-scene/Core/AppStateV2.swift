import Foundation

// State model for the v1 UI. It holds AppConfig (the persisted settings) as-is via @Published,
// and delegates the actual work (saving and applying) to the Wave 4 AppControllerV2 through
// AppActionsV2. The UI layer (SwiftUI) only renders this AppStateV2 and never touches
// ConfigStore or the like directly.

/// Display-facing information about a single display.
/// Example: `DisplayInfo(displayUUID: uuid, name: "Built-in Retina Display", isConnected: true)`
struct DisplayInfo: Identifiable {
  let displayUUID: String
  let name: String
  let isConnected: Bool

  var id: String { displayUUID }
}

/// Entry point that receives action requests from the UI. Implemented by the Wave 4
/// AppControllerV2. AppStateV2.actions holds it weakly (so the UI side does not influence
/// the controller's lifetime).
@MainActor
protocol AppActionsV2: AnyObject {
  /// Updates the mode of the given display. Every kind of change — mode, file, folder,
  /// interval, or scaling — is reported through this single call (no partial-update API
  /// is provided).
  func updateDisplayMode(displayUUID: String, mode: DisplayMode)
  /// Pauses or resumes playback on all displays.
  func setGloballyPaused(_ paused: Bool)
  /// Toggles the feature that falls back to a still image while conserving power
  /// (on battery, in Low Power Mode, or under thermal pressure).
  func setPowerSavingEnabled(_ enabled: Bool)
  /// Switches the behavior applied when a manual (external) wallpaper change is detected (P0-2)
  func setExternalChangePolicy(_ policy: ExternalChangePolicy)
  /// Resets all "unmanaged" spaces on the given display so they become eligible for
  /// automatic assignment again (P0-2)
  func resetUnmanagedSpaces(displayUUID: String)
  /// Re-shuffles the assignments of the given display (folder mode) right now. The currently
  /// visible space switches immediately; other spaces switch on their next visit. Does nothing
  /// for single/standard displays.
  func reassignNow(displayUUID: String)
  /// Toggles launch-at-login.
  func setLaunchAtLogin(_ enabled: Bool)
  /// Opens the settings window.
  func openSettingsWindow()
  /// Quits the app.
  func quitApp()
}

/// The single source of state the UI renders. In addition to config — which mirrors the
/// contents of ConfigStore exactly — it holds the list of connected displays (displays),
/// the power-saving state, and the most recent error.
/// displays is the merged result of "displays currently connected" and "past displays still
/// recorded in config.displays"; the merging itself is done by Wave 4 (AppControllerV2).
/// Here we only render it.
@MainActor
final class AppStateV2: ObservableObject {
  @Published var config: AppConfig = .empty()
  @Published var displays: [DisplayInfo] = []
  @Published var isPowerSaving = false
  @Published var lastError: String?
  /// Spaces (bindings) that have become "unmanaged" in folder mode. key = displayUUID (P0-2)
  @Published var unmanagedSpaces: [String: [SpaceBinding]] = [:]

  /// Delegate for action requests coming from the UI. The controller that owns the actual
  /// logic holds a strong reference to this object, so we keep a weak reference here to
  /// avoid a retain cycle.
  weak var actions: AppActionsV2?
}
