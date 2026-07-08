import Foundation
import os

/// Thin wrapper around os.Logger. Also appends the same content to a file (for headless checks).
enum Log {
  private static let subsystem = "com.star-village.wall-scene"
  private static let isoFormatter = ISO8601DateFormatter()

  private static let fileQueue = DispatchQueue(label: "com.star-village.wall-scene.log")

  private static let logFileName = "wallscene.log"
  private static let oldLogFileName = "wallscene.log.old"
  /// Rotation threshold: once the active log file reaches this size, it is moved aside to
  /// `wallscene.log.old` (replacing any previous `.old` file) and a fresh log is started. This
  /// keeps the file log — which is not privacy-scrubbed and may contain full user paths — from
  /// growing without bound in a long-running, login-item app.
  private static let maxLogFileSize: UInt64 = 2 * 1024 * 1024  // 2 MB

  static func info(_ category: String, _ message: String) {
    Logger(subsystem: subsystem, category: category).info("\(message, privacy: .public)")
    write(level: "INFO", category: category, message: message)
  }

  static func warn(_ category: String, _ message: String) {
    Logger(subsystem: subsystem, category: category).warning("\(message, privacy: .public)")
    write(level: "WARN", category: category, message: message)
  }

  static func error(_ category: String, _ message: String) {
    Logger(subsystem: subsystem, category: category).error("\(message, privacy: .public)")
    write(level: "ERROR", category: category, message: message)
  }

  private static func write(level: String, category: String, message: String) {
    let line = "\(isoFormatter.string(from: Date())) [\(level)] [\(category)] \(message)\n"
    fileQueue.sync {
      let url = Paths.logsDir.appendingPathComponent(logFileName)
      guard let data = line.data(using: .utf8) else { return }
      let fm = FileManager.default
      if !fm.fileExists(atPath: url.path) {
        try? FileManager.default.createDirectory(
          at: Paths.logsDir, withIntermediateDirectories: true)
        fm.createFile(atPath: url.path, contents: nil)
      } else {
        rotateIfNeeded(url: url, fileManager: fm)
      }
      if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(data)
      }
    }
  }

  /// Moves the active log aside to a single `.old` generation once it exceeds
  /// `maxLogFileSize`, then starts a fresh, empty log file. Must be called from within
  /// `fileQueue` to stay serialized with concurrent writes.
  private static func rotateIfNeeded(url: URL, fileManager fm: FileManager) {
    guard let attributes = try? fm.attributesOfItem(atPath: url.path),
      let size = attributes[.size] as? UInt64,
      size >= maxLogFileSize
    else { return }

    let oldURL = Paths.logsDir.appendingPathComponent(oldLogFileName)
    try? fm.removeItem(at: oldURL)
    try? fm.moveItem(at: url, to: oldURL)
    fm.createFile(atPath: url.path, contents: nil)
  }
}
