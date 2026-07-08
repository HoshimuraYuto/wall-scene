import AppKit
import CoreGraphics

// Extension for deriving a stable display identifier from NSScreen.
// The goal is to return the same UUID for the same display across reboots and cable
// re-plugs (CGDisplayCreateUUIDFromDisplayID is stable because it is computed from
// EDID information and the like).

extension NSScreen {
  /// A stable identifier string for this display.
  /// Resolved in the order NSScreenNumber → CGDirectDisplayID → CGDisplayCreateUUIDFromDisplayID.
  /// Falls back to "unknown-<NSScreenNumber>" when it cannot be obtained.
  /// Usage: `let uuid = NSScreen.main?.stableDisplayUUID`
  var stableDisplayUUID: String {
    guard
      let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    else {
      return "unknown-unknown"
    }
    let displayID = CGDirectDisplayID(screenNumber.uint32Value)

    guard let uuidRef = CGDisplayCreateUUIDFromDisplayID(displayID) else {
      return "unknown-\(screenNumber.uint32Value)"
    }
    let cfUUID = uuidRef.takeRetainedValue()
    guard let uuidString = CFUUIDCreateString(nil, cfUUID) as String? else {
      return "unknown-\(screenNumber.uint32Value)"
    }
    return uuidString
  }

  /// Reverse lookup of an NSScreen from a stableDisplayUUID (linear search).
  /// Used by the settings UI preview (e.g. fetching the current wallpaper image).
  /// Usage: `let screen = NSScreen.screen(forStableDisplayUUID: uuid)`
  static func screen(forStableDisplayUUID uuid: String) -> NSScreen? {
    NSScreen.screens.first { $0.stableDisplayUUID == uuid }
  }
}
