import Foundation
import ServiceManagement

/// Thin wrapper around SMAppService.mainApp that handles the registration state of
/// launch-at-login (Login Item)
@MainActor
final class LoginItemManager {
  /// Whether the app is currently enabled as a login item
  var isEnabled: Bool {
    SMAppService.mainApp.status == .enabled
  }

  /// Toggles launch-at-login on or off
  ///
  /// Note: register()/unregister() can fail in an unsigned, unbundled state during
  /// development (e.g. when run via swift build). They are expected to work reliably
  /// only when the app is properly signed and bundled as an App.
  func setEnabled(_ enabled: Bool) throws {
    Log.info("loginItem", "setEnabled \(enabled)")
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
    } catch {
      Log.warn(
        "loginItem",
        "setEnabled failed (can fail when running unsigned/unbundled): \(error.localizedDescription)"
      )
      throw error
    }
  }
}
