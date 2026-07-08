import Foundation

// Data model definitions for v1 (Contracts v2). A new set of types for migrating from the
// Assignment-based design to a "per-display configuration" based one.
// The existing Contracts.swift is left untouched; both coexist until the v1 implementation settles.

// MARK: - Scaling

/// How a video is fitted to the screen
/// Usage: `let mode: ScalingMode = .fill`
enum ScalingMode: String, Codable {
  case fill  // Scale up to fill the entire screen (default)
  case fit  // Show the whole frame without cropping (letterboxed/pillarboxed)
}

// MARK: - Policy for manual wallpaper changes (external changes)

/// Behavior when, on arriving at a space (or on a re-check while staying there), we detect that
/// a wallpaper that was supposed to be managed by Wall Scene has been replaced with something
/// other than a known beacon/poster (i.e. the user changed it manually).
/// Default is ask (never overwrite silently).
/// Usage: `let policy: ExternalChangePolicy = .ask`
enum ExternalChangePolicy: String, Codable {
  /// Ask the user "Do you want to let Wall Scene manage this space again?"; if accepted,
  /// re-beacon the space, otherwise leave it unmanaged (default)
  case ask
  /// Always re-beacon automatically and keep managing the space
  case alwaysRebeacon
  /// Leave the space unmanaged (show no window; respect the user's wallpaper as is)
  case leaveUnmanaged
}

// MARK: - Reshuffle timing for folder mode

/// When to reshuffle the "space (beacon) <-> video" mapping in folder mode.
/// The options mirror macOS's built-in wallpaper shuffle choices (interval / at login / on wake).
/// Usage: `let timing: RotationTiming = .interval(minutes: 30)`
///
/// On the Codable representation: left to compiler synthesis for the same reason as DisplayMode
/// (it comes out as `{"interval":{"minutes":30}}` / `{"onLogin":{}}` / `{"onWake":{}}`).
enum RotationTiming: Codable, Hashable {
  case interval(minutes: Int)
  case onLogin
  case onWake
  // "Every 5 seconds" (the shortest interval of macOS's built-in shuffle) is intentionally
  // unsupported: how the beacon approach interacts with the macOS wallpaper cache when
  // rewriting wallpapers at high frequency is unverified
}

// MARK: - Per-display mode

/// Control mode for a single display.
/// Usage: `let mode: DisplayMode = .single(videoPath: "/path/to/video.mp4", scaling: .fill)`
///
/// On the Codable representation:
/// - standard/single can still be left to the same shape as compiler synthesis
///   (`{"single":{"videoPath":...,"scaling":...}}`). Only folder needs special handling because
///   old config.json files carry a flat `intervalMinutes: Int` key, so we follow the same
///   "hand-written init(from:) using decodeIfPresent" convention as AppConfig/SpaceBinding and
///   provide backward compatibility that reads the old key as `.interval(minutes:)`
///   (implemented as the `extension DisplayMode: Decodable` equivalent near the end of this file;
///   encode(to:) stays compiler-synthesized).
enum DisplayMode: Equatable {
  case standard
  case single(videoPath: String, scaling: ScalingMode)
  case folder(folderPath: String, timing: RotationTiming, scaling: ScalingMode)
}

extension DisplayMode: Codable {
  private enum CodingKeys: String, CodingKey {
    case standard
    case single
    case folder
  }

  private struct SingleParams: Decodable {
    var videoPath: String
    var scaling: ScalingMode
  }

  private enum FolderKeys: String, CodingKey {
    case folderPath
    case timing
    case intervalMinutes  // Legacy key (pre-RotationTiming). Used only when timing is absent
    case scaling
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    if container.contains(.standard) {
      self = .standard
      return
    }

    if container.contains(.single) {
      let single = try container.decode(SingleParams.self, forKey: .single)
      self = .single(videoPath: single.videoPath, scaling: single.scaling)
      return
    }

    if container.contains(.folder) {
      let nested = try container.nestedContainer(keyedBy: FolderKeys.self, forKey: .folder)
      let folderPath = try nested.decode(String.self, forKey: .folderPath)
      let scaling = try nested.decode(ScalingMode.self, forKey: .scaling)
      let timing: RotationTiming
      if let decoded = try nested.decodeIfPresent(RotationTiming.self, forKey: .timing) {
        timing = decoded
      } else {
        // Compatibility with old config.json (which only carries intervalMinutes: Int)
        let legacyMinutes = try nested.decode(Int.self, forKey: .intervalMinutes)
        timing = .interval(minutes: legacyMinutes)
      }
      self = .folder(folderPath: folderPath, timing: timing, scaling: scaling)
      return
    }

    throw DecodingError.dataCorrupted(
      DecodingError.Context(
        codingPath: decoder.codingPath,
        debugDescription: "DisplayMode: unrecognized case (not one of standard/single/folder)"
      ))
  }

  // encode(to:) is left to compiler synthesis. Even with a hand-written init(from:), the
  // Encodable side is synthesized independently, so output is always in the new format
  // (the timing key). Same convention as AppConfig/SpaceBinding; see the comment at the top
  // of ContractsV2.swift.
}

// MARK: - Per-display configuration

/// Configuration for a single display. Stored in AppConfig.displays keyed by displayUUID.
/// Usage: `DisplayConfig(displayUUID: screen.stableDisplayUUID, displayName: screen.localizedName, mode: .standard)`
struct DisplayConfig: Codable, Equatable {
  var displayUUID: String
  var displayName: String
  var mode: DisplayMode
}

// MARK: - App-wide configuration

/// App-wide persistent settings. ConfigStore saves this as config.json.
/// Usage: `let config = AppConfig(version: 2, displays: [:], launchAtLogin: false, isGloballyPaused: false)`
///
/// On backward compatibility for powerSavingEnabled / externalChangePolicy:
/// Existing config.json files (older version=2 files that lack these keys) must remain readable,
/// so init(from:) is hand-written with powerSavingEnabled as decodeIfPresent ?? true and
/// externalChangePolicy as decodeIfPresent ?? .ask. To keep existing construction sites
/// (empty() etc.) compiling, a memberwise-equivalent init with default arguments is also
/// hand-written. encode(to:) is left to compiler synthesis (since CodingKeys lists every
/// property explicitly, synthesis still works even with a hand-written init(from:)).
struct AppConfig: Codable, Equatable {
  var version: Int  // = 2 (the old assignments.json is not read)
  var displays: [String: DisplayConfig]  // key = displayUUID
  var launchAtLogin: Bool
  var isGloballyPaused: Bool
  // Whether to fall back to a still image while power-constrained (on battery, Low Power Mode,
  // or thermal pressure). Default true
  var powerSavingEnabled: Bool
  // Behavior when a manual wallpaper change (external change) is detected. Default ask
  var externalChangePolicy: ExternalChangePolicy

  enum CodingKeys: String, CodingKey {
    case version
    case displays
    case launchAtLogin
    case isGloballyPaused
    case powerSavingEnabled
    case externalChangePolicy
  }

  init(
    version: Int,
    displays: [String: DisplayConfig],
    launchAtLogin: Bool,
    isGloballyPaused: Bool,
    powerSavingEnabled: Bool = true,
    externalChangePolicy: ExternalChangePolicy = .ask
  ) {
    self.version = version
    self.displays = displays
    self.launchAtLogin = launchAtLogin
    self.isGloballyPaused = isGloballyPaused
    self.powerSavingEnabled = powerSavingEnabled
    self.externalChangePolicy = externalChangePolicy
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    version = try container.decode(Int.self, forKey: .version)
    displays = try container.decode([String: DisplayConfig].self, forKey: .displays)
    launchAtLogin = try container.decode(Bool.self, forKey: .launchAtLogin)
    isGloballyPaused = try container.decode(Bool.self, forKey: .isGloballyPaused)
    powerSavingEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .powerSavingEnabled) ?? true
    externalChangePolicy =
      try container.decodeIfPresent(ExternalChangePolicy.self, forKey: .externalChangePolicy)
      ?? .ask
  }

  static func empty() -> AppConfig {
    AppConfig(
      version: 2, displays: [:], launchAtLogin: false, isGloballyPaused: false,
      powerSavingEnabled: true, externalChangePolicy: .ask)
  }
}

// MARK: - Folder-mode space assignment

/// The "space (beacon) <-> video" mapping in folder mode. Persisted across restarts.
/// Usage: `SpaceBinding(beaconUUID: uuid, displayUUID: displayUUID, videoPath: path, assignedAt: Date())`
///
/// On backward compatibility for scaling/renderedPixelWidth/renderedPixelHeight:
/// Fields added to record "with which scaling and at which screen pixel size" the beacon HEIC
/// was rendered. Without them, the branch that reuses an existing beacon on space arrival (b-1)
/// cannot detect a scaling change, causing the bug where toggling fit/fill in folder mode never
/// changes the appearance of already-assigned spaces
/// (BeaconRegenerationPolicy.needsRegeneration uses these for its decision).
/// Existing space-bindings.json files (the old format lacking these keys) must remain readable,
/// so init(from:) is hand-written in the same convention as AppConfig.powerSavingEnabled,
/// allowing nil via decodeIfPresent. nil is interpreted as "old-generation beacon (from before
/// scaling was baked in, or before the change-detection mechanism existed) = needs regeneration"
/// (decided on the BeaconRegenerationPolicy side).
///
/// On isUnmanaged/unmanagedImagePath (P0-2 self-healing against manual wallpaper changes):
/// When an external change (the user manually changing the wallpaper) is detected and the policy
/// is leaveUnmanaged (or ask with the user declining management), this marks the space so it is
/// excluded from future assignment and self-healing. Once a binding has isUnmanaged=true, its
/// beaconUUID no longer appears in desktopImageURL (the beacon file itself is no longer used),
/// so re-recognition on revisit uses unmanagedImagePath (the wallpaper path at the moment of
/// detection) instead (see ExternalWallpaperChangeDetector.isKnownUnmanagedPath). Old-format
/// space-bindings.json files lack these keys, so, in the same convention as the other added
/// fields, they tolerate nil/false via decodeIfPresent. encode(to:) is left to compiler
/// synthesis (since CodingKeys lists every property explicitly, synthesis still works even with
/// a hand-written init(from:)).
struct SpaceBinding: Codable, Equatable {
  var beaconUUID: UUID
  var displayUUID: String
  var videoPath: String
  var assignedAt: Date
  var scaling: ScalingMode?
  var renderedPixelWidth: Int?
  var renderedPixelHeight: Int?
  var isUnmanaged: Bool
  var unmanagedImagePath: String?

  enum CodingKeys: String, CodingKey {
    case beaconUUID
    case displayUUID
    case videoPath
    case assignedAt
    case scaling
    case renderedPixelWidth
    case renderedPixelHeight
    case isUnmanaged
    case unmanagedImagePath
  }

  init(
    beaconUUID: UUID,
    displayUUID: String,
    videoPath: String,
    assignedAt: Date,
    scaling: ScalingMode? = nil,
    renderedPixelWidth: Int? = nil,
    renderedPixelHeight: Int? = nil,
    isUnmanaged: Bool = false,
    unmanagedImagePath: String? = nil
  ) {
    self.beaconUUID = beaconUUID
    self.displayUUID = displayUUID
    self.videoPath = videoPath
    self.assignedAt = assignedAt
    self.scaling = scaling
    self.renderedPixelWidth = renderedPixelWidth
    self.renderedPixelHeight = renderedPixelHeight
    self.isUnmanaged = isUnmanaged
    self.unmanagedImagePath = unmanagedImagePath
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    beaconUUID = try container.decode(UUID.self, forKey: .beaconUUID)
    displayUUID = try container.decode(String.self, forKey: .displayUUID)
    videoPath = try container.decode(String.self, forKey: .videoPath)
    assignedAt = try container.decode(Date.self, forKey: .assignedAt)
    scaling = try container.decodeIfPresent(ScalingMode.self, forKey: .scaling)
    renderedPixelWidth = try container.decodeIfPresent(Int.self, forKey: .renderedPixelWidth)
    renderedPixelHeight = try container.decodeIfPresent(Int.self, forKey: .renderedPixelHeight)
    isUnmanaged = try container.decodeIfPresent(Bool.self, forKey: .isUnmanaged) ?? false
    unmanagedImagePath = try container.decodeIfPresent(String.self, forKey: .unmanagedImagePath)
  }
}

// MARK: - Configuration persistence

/// Responsible for reading and writing AppConfig.
/// Usage: `let config = try await configStore.load()`
protocol ConfigStoring: AnyObject {
  /// Load the saved configuration. Returns the defaults if the file is missing/unreadable
  func load() async throws -> AppConfig
  /// Save the configuration (atomic write)
  func save(_ config: AppConfig) async throws
  /// Current value of the most recently loaded/saved configuration (defaults if never loaded)
  func currentConfig() async -> AppConfig
}

// MARK: - Media folder scanning

/// One playable/displayable media item found by a folder scan (a video, GIF, or image).
/// Usage: `let item = MediaItem(url: fileURL, kind: .video)`
struct MediaItem: Equatable {
  var url: URL
  var kind: MediaKind
}

/// Lists the playable/displayable media files (videos, GIFs, and images) in a given folder.
/// Usage: `let items = try await mediaLibrary.scanPlayableMedia(in: folderURL)`
protocol MediaLibraryScanning: AnyObject {
  /// Scan only the top level of the folder and return the media judged playable/displayable,
  /// ordered by file name. Videos are judged via AVURLAsset.isPlayable; GIFs/images by whether
  /// ImageIO can read them
  func scanPlayableMedia(in folderURL: URL) async -> [MediaItem]
}
