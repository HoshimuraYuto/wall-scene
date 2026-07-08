import Foundation

// JSON persistence destination for AppConfig. The existing Paths.swift is left untouched;
// the v2 path is added as an extension (Paths is just an enum namespace following the existing
// code's conventions, so it is safe to extend).
extension Paths {
  /// Storage location for AppConfig (v2): ~/Library/Application Support/WallScene/config.json
  static var configV2URL: URL {
    appSupportDir.appendingPathComponent("config.json")
  }
}

/// Store that persists AppConfig to a JSON file.
/// Usage example: `let config = try await ConfigStore().load()`
final class ConfigStore: ConfigStoring {
  private let fileURL: URL
  private var cached: AppConfig?
  private let queue = DispatchQueue(label: "com.star-village.wall-scene.configStore")

  init(fileURL: URL = Paths.configV2URL) {
    self.fileURL = fileURL
  }

  func load() async throws -> AppConfig {
    let url = fileURL
    let config: AppConfig = await withCheckedContinuation { continuation in
      queue.async {
        let result = Self.readConfig(at: url)
        continuation.resume(returning: result)
      }
    }
    cached = config
    return config
  }

  func save(_ config: AppConfig) async throws {
    let url = fileURL
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      queue.async {
        do {
          try Self.writeConfig(config, to: url)
          continuation.resume()
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
    cached = config
  }

  func currentConfig() async -> AppConfig {
    if let cached { return cached }
    return (try? await load()) ?? .empty()
  }

  // MARK: - I/O

  private static func readConfig(at url: URL) -> AppConfig {
    guard let data = try? Data(contentsOf: url) else {
      Log.info("configStore", "config.json not found; using default values")
      return .empty()
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    do {
      return try decoder.decode(AppConfig.self, from: data)
    } catch {
      Log.warn(
        "configStore",
        "Failed to read config.json; using default values: \(error.localizedDescription)")
      return .empty()
    }
  }

  private static func writeConfig(_ config: AppConfig, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let data = try encoder.encode(config)
      try data.write(to: url, options: .atomic)
    } catch {
      Log.error("configStore", "Failed to save config.json: \(error.localizedDescription)")
      throw WallSceneError.storeIOFailed(error.localizedDescription)
    }
  }
}
