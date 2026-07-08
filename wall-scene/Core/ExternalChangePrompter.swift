import AppKit

/// The means of asking the user "Do you want to let Wall Scene manage this space again?" when
/// ExternalChangePolicy is .ask. Separated from ExternalWallpaperChangeDetector (pure logic) so
/// that the AppKit dependency stays confined to this file (the same idea as the
/// BeaconRegenerationPolicy/FolderSpaceCoordinator separation).
///
/// Why NSAlert was chosen as the presentation method:
/// User notifications via UNUserNotificationCenter were also considered, but for an ad-hoc
/// signed app, obtaining notification permission (UNUserNotificationCenter.requestAuthorization)
/// can be unreliable depending on the user's environment (the permission is reset every time the
/// signature is regenerated, the path into System Settings is hard to discover, etc.).
/// NSAlert requires no entitlements or permissions and can be shown reliably even from a
/// menu bar app (LSUIElement), so weighing implementation cost against reliability, NSAlert
/// was adopted.
/// Trade-off: NSAlert.runModal() is modal, so until the user responds, the caller (the
/// processing for the affected display in FolderSpaceCoordinator/SingleVideoController) does
/// not proceed. Processing for other displays and other spaces is unaffected (the call is made
/// per currently visible space).
@MainActor
protocol ExternalChangePrompting: AnyObject {
  /// Asks "Do you want to let Wall Scene manage this space again?" and returns the user's answer
  /// (true if accepted = re-beacon / re-apply the poster; false if declined = mark the space
  /// unmanaged)
  /// - Parameters:
  ///   - displayName: Name of the target display (included in the message)
  ///   - mediaName: File name of the assigned media (included in the message)
  func promptRebeaconAcceptance(displayName: String, mediaName: String) async -> Bool
}

@MainActor
final class NSAlertExternalChangePrompter: ExternalChangePrompting {
  func promptRebeaconAcceptance(displayName: String, mediaName: String) async -> Bool {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = String(localized: "The wallpaper was changed manually")
    alert.informativeText = String(
      localized:
        "On the space shown on “\(displayName)”, the wallpaper set by Wall Scene (\(mediaName)) has been replaced with a different wallpaper. Do you want to let Wall Scene manage this space again?\n\nIf you choose “Don’t Manage This Space”, the current wallpaper is kept and Wall Scene will no longer manage this space. You can resume managing it anytime in settings."
    )
    alert.addButton(withTitle: String(localized: "Resume Managing"))
    alert.addButton(withTitle: String(localized: "Don’t Manage This Space"))
    let response = alert.runModal()
    Log.info(
      "externalChangePrompter",
      "promptRebeaconAcceptance display=\(displayName) media=\(mediaName) accepted=\(response == .alertFirstButtonReturn)"
    )
    return response == .alertFirstButtonReturn
  }
}
