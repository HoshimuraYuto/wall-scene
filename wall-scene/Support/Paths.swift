import Foundation

/// Storage locations used by the app
enum Paths {
  /// For on-device testing: when the launch argument `--debug-data-dir <path>` is given, use
  /// that directory instead of Application Support (an isolation mechanism so testing does not
  /// pollute the user's real config.json / space-bindings.json / Beacons). CommandLine.arguments
  /// never changes while the process is running, so evaluating it once at launch is sufficient
  private static let debugDataDirOverride: URL? = {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: "--debug-data-dir"), index + 1 < arguments.count
    else {
      return nil
    }
    return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
  }()

  static var appSupportDir: URL {
    if let debugDataDirOverride {
      return debugDataDirOverride
    }
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("WallScene", isDirectory: true)
  }

  static var videosDir: URL {
    appSupportDir.appendingPathComponent("Videos", isDirectory: true)
  }

  static var beaconsDir: URL {
    appSupportDir.appendingPathComponent("Beacons", isDirectory: true)
  }

  static var logsDir: URL {
    appSupportDir.appendingPathComponent("Logs", isDirectory: true)
  }

  /// Cache destination for the still images of media saved for single-mode wallpaper
  /// replacement (the Mission Control workaround): the first frame for videos/GIFs, and a
  /// re-encoded copy for images as well, for uniformity
  static var singlePostersDir: URL {
    appSupportDir.appendingPathComponent("SinglePosters", isDirectory: true)
  }

  /// Creates all required directories
  static func ensureDirectories() {
    let dirs = [appSupportDir, videosDir, beaconsDir, logsDir, singlePostersDir]
    for dir in dirs {
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
  }
}
