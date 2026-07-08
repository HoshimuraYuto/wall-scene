import Foundation

// Storage location for [SpaceBinding] (folder mode's "space <-> video" mapping). Rather than
// modifying the existing Paths.swift, add the v1 path in the same style as ConfigStore.swift
// (as an extension).
extension Paths {
  /// Storage location for the SpaceBinding array:
  /// ~/Library/Application Support/WallScene/space-bindings.json
  static var spaceBindingsURL: URL {
    appSupportDir.appendingPathComponent("space-bindings.json")
  }
}

/// Store that persists folder mode's "space (beacon) <-> video" mappings (SpaceBinding) to a
/// JSON file. Follows the same style as AssignmentStore (a naive implementation that keeps the
/// whole array in memory and performs an atomic write on every change).
/// Usage example: `let videoURL = bindingStore.binding(for: uuid)?.videoPath`
@MainActor
final class SpaceBindingStore {
  private(set) var bindings: [SpaceBinding] = []

  private let fileURL: URL

  /// Fires every time the bindings change (i.e. whenever save() is called). AppControllerV2
  /// subscribes to this in order to reflect the P0-2 "unmanaged spaces" list into AppStateV2
  /// (recomputing only when the settings screen is opened would miss changes originating from
  /// FolderSpaceCoordinator).
  var onChange: (() -> Void)?

  init(fileURL: URL? = nil) {
    self.fileURL = fileURL ?? Paths.spaceBindingsURL
    load()
  }

  /// Returns the binding corresponding to the given beaconUUID
  func binding(for beaconUUID: UUID) -> SpaceBinding? {
    bindings.first { $0.beaconUUID == beaconUUID }
  }

  /// Lists the bindings that belong to the given display
  func bindings(displayUUID: String) -> [SpaceBinding] {
    bindings.filter { $0.displayUUID == displayUUID }
  }

  /// Adds or updates (replaces the existing binding whose beaconUUID matches, if any)
  func upsert(_ binding: SpaceBinding) {
    if let index = bindings.firstIndex(where: { $0.beaconUUID == binding.beaconUUID }) {
      bindings[index] = binding
    } else {
      bindings.append(binding)
    }
    save()
  }

  /// Removes a binding
  func remove(beaconUUID: UUID) {
    bindings.removeAll { $0.beaconUUID == beaconUUID }
    save()
  }

  // MARK: - I/O

  private func load() {
    guard let data = try? Data(contentsOf: fileURL) else { return }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    if let decoded = try? decoder.decode([SpaceBinding].self, from: data) {
      bindings = decoded
    } else {
      // Start from empty when the file is corrupted (as required). The existing file is left
      // untouched rather than overwritten; it will be atomically rewritten with correct content
      // on the next upsert.
      Log.warn("spaceBindingStore", "Failed to load space-bindings.json; starting from empty")
    }
  }

  private func save() {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = .prettyPrinted
    do {
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let data = try encoder.encode(bindings)
      try data.write(to: fileURL, options: .atomic)
    } catch {
      // The caller (FolderSpaceCoordinator) follows a no-crash policy, so we do not throw here
      // and only log the error. Saving will be attempted again on the next refresh.
      Log.error(
        "spaceBindingStore", "Failed to save space-bindings.json: \(error.localizedDescription)")
    }
    onChange?()
  }
}
