import AVFoundation
import AppKit

// MARK: - Errors
enum WallSceneError: LocalizedError {
  case exportFailed(String)
  case beaconWriteFailed(String)
  case wallpaperSetFailed(String)
  case storeIOFailed(String)

  var errorDescription: String? {
    switch self {
    case .exportFailed(let m): return String(localized: "Failed to convert the video: \(m)")
    case .beaconWriteFailed(let m):
      return String(localized: "Failed to generate the beacon image: \(m)")
    case .wallpaperSetFailed(let m): return String(localized: "Failed to set the wallpaper: \(m)")
    case .storeIOFailed(let m): return String(localized: "Failed to save settings: \(m)")
    }
  }
}

// MARK: - Beacons (space identification via wallpaper still images)
@MainActor
protocol BeaconManaging: AnyObject {
  // scaling: fill/fit used when setting the image as the wallpaper. A beacon for a video/GIF
  // (its first frame) is normally hidden right away by the playback window, but when an image
  // medium itself becomes the beacon, this is exactly what ends up on screen — so pass the
  // display's scaling setting through as-is
  func setBeacon(_ uuid: UUID, on screen: NSScreen, scaling: ScalingMode) throws
  // Resolve the beacon UUID from the current space's wallpaper, with retries. nil if the
  // wallpaper is not a beacon
  func currentBeaconUUID(on screen: NSScreen) async -> UUID?
  // Immediate read without retries (for use right after launch)
  func peekBeaconUUID(on screen: NSScreen) -> UUID?
}

// MARK: - Wallpaper window
@MainActor
protocol WallpaperWindowControlling: AnyObject {
  var beaconUUID: UUID { get }
  var screenKey: String { get }
  var isOnActiveSpace: Bool { get }
  var isOrderedIn: Bool { get }
  var onVisibilityChange: ((Bool) -> Void)? { get set }  // occlusion changes (true = visible)
  func attach(playerLayer: AVPlayerLayer)
  // For GIF animation. Adds an NSImageView to the host view that places the image within the
  // bounds as fill/fit while preserving aspect ratio, and returns it (the caller controls
  // toggling animates on/off)
  func attachGIFImageView(image: NSImage, gravity: AVLayerVideoGravity) -> NSImageView
  func show()
  func hide()
  func close()
}

@MainActor
protocol WallpaperWindowFactory: AnyObject {
  func makeWindow(beaconUUID: UUID, screen: NSScreen) -> WallpaperWindowControlling
}

// MARK: - Playback
@MainActor
protocol PlaybackControlling: AnyObject {
  var isGloballyPaused: Bool { get set }
  var isPowerSaving: Bool { get }
  /// ON/OFF switch for the feature that falls back to a still image while power-constrained
  /// (on battery, Low Power Mode, or thermal pressure). While false, isPowerSaving never
  /// becomes true even if the internal PowerMonitor detects a constrained state.
  /// Defaults to true. When the setting changes, re-evaluate immediately against the current
  /// constraint state
  var powerSavingEnabled: Bool { get set }
  var onPowerStateChange: (() -> Void)? { get set }  // called when the power-saving state changes
  func startPlayback(
    videoURL: URL, in window: WallpaperWindowControlling, gravity: AVLayerVideoGravity)
  // GIFs are driven as animated images via NSImageView.animates (AVPlayer is not used)
  func startGIFPlayback(
    imageURL: URL, in window: WallpaperWindowControlling, gravity: AVLayerVideoGravity)
  func stopPlayback(beaconUUID: UUID)
  func stopAll()
  // Whether a playback entry for the given (beaconUUID, screenKey) is currently registered.
  // Used by FolderSpaceCoordinator.ensureWindow to detect the case where "the window is still
  // shown but only its playback entry has been lost" (e.g. the entries mapping got swapped out
  // when the duplicate-window self-healing reclaimed one of the windows) and re-attach playback
  // (while the power-saving fallback is active, ensureWindow itself returns early, so this
  // query never needs to contend with power-saving)
  func hasActiveEntry(beaconUUID: UUID, screenKey: String) -> Bool
}

// v1 consolidation: when the gravity parameter was added for folder-mode scaling (fill/fit)
// support, the two-argument version was kept as a default implementation so that existing
// call sites compile unchanged (default gravity = .resizeAspectFill = identical to the old
// behavior).
extension PlaybackControlling {
  func startPlayback(videoURL: URL, in window: WallpaperWindowControlling) {
    startPlayback(videoURL: videoURL, in: window, gravity: .resizeAspectFill)
  }
}
