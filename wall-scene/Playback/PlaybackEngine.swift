import AVFoundation
import AppKit

/// Common interface representing the playback stack for a single wallpaper window.
/// An abstraction that lets video (AVQueuePlayer) and GIF (NSImageView.animates) be driven
/// by the same occlusion / pause / power-saving logic.
private protocol PlaybackEntry: AnyObject {
  var window: WallpaperWindowControlling { get }
  /// Visibility as of the most recent occlusion notification (or isOnActiveSpace at start)
  var isVisible: Bool { get set }
  func play()
  func pause()
  /// Tears down the player/looper/layer (or imageView); closing the window itself is the
  /// caller's responsibility
  func teardown()
}

/// Playback stack for video (player / looper / layer)
private final class VideoPlaybackEntry: PlaybackEntry {
  let window: WallpaperWindowControlling
  let player: AVQueuePlayer
  let looper: AVPlayerLooper
  let playerLayer: AVPlayerLayer
  var isVisible: Bool = false

  init(
    window: WallpaperWindowControlling, player: AVQueuePlayer, looper: AVPlayerLooper,
    playerLayer: AVPlayerLayer
  ) {
    self.window = window
    self.player = player
    self.looper = looper
    self.playerLayer = playerLayer
  }

  func play() { player.play() }
  func pause() { player.pause() }

  func teardown() {
    player.pause()
    playerLayer.removeFromSuperlayer()
  }
}

/// Playback stack for GIFs (animated images). Driven via NSImageView.animates rather than AVPlayer
private final class GIFPlaybackEntry: PlaybackEntry {
  let window: WallpaperWindowControlling
  let imageView: NSImageView
  var isVisible: Bool = false

  init(window: WallpaperWindowControlling, imageView: NSImageView) {
    self.window = window
    self.imageView = imageView
  }

  func play() { imageView.animates = true }
  func pause() { imageView.animates = false }

  func teardown() {
    imageView.animates = false
    imageView.removeFromSuperview()
  }
}

/// Engine that manages media playback (video/GIF) per (beaconUUID, screenKey)
@MainActor
final class PlaybackEngine: PlaybackControlling {
  private struct Key: Hashable {
    let beaconUUID: UUID
    let screenKey: String
  }

  private var entries: [Key: PlaybackEntry] = [:]
  private let powerMonitor = PowerMonitor()

  var onPowerStateChange: (() -> Void)?
  private(set) var isPowerSaving: Bool = false

  /// On/off switch for the power-saving retreat feature itself. The moment this is set to false,
  /// if a retreat is in progress it is released immediately (rebuilding the windows afterwards is
  /// done by the caller via onPowerStateChange, same as the existing mechanism). The moment it is
  /// set back to true, if we are already constrained, retreat immediately
  var powerSavingEnabled: Bool = true {
    didSet {
      guard powerSavingEnabled != oldValue else { return }
      applyEffectivePowerState()
    }
  }

  var isGloballyPaused: Bool = false {
    didSet {
      guard isGloballyPaused != oldValue else { return }
      if isGloballyPaused {
        for entry in entries.values { entry.pause() }
        Log.info("playback", "globally paused")
      } else {
        for entry in entries.values where entry.isVisible && !isPowerSaving {
          entry.play()
        }
        Log.info("playback", "globally resumed")
      }
    }
  }

  init() {
    powerMonitor.onChange = { [weak self] constrained in
      self?.handlePowerStateChange(constrained)
    }
  }

  func startPlayback(
    videoURL: URL, in window: WallpaperWindowControlling, gravity: AVLayerVideoGravity
  ) {
    let item = AVPlayerItem(url: videoURL)
    let player = AVQueuePlayer()
    let looper = AVPlayerLooper(player: player, templateItem: item)
    player.isMuted = true
    // Wallpaper playback must not prevent the display from sleeping
    player.preventsDisplaySleepDuringVideoPlayback = false

    let playerLayer = AVPlayerLayer(player: player)
    playerLayer.videoGravity = gravity
    window.attach(playerLayer: playerLayer)

    let entry = VideoPlaybackEntry(
      window: window, player: player, looper: looper, playerLayer: playerLayer)
    register(entry, kindLabel: "video")
  }

  func startGIFPlayback(
    imageURL: URL, in window: WallpaperWindowControlling, gravity: AVLayerVideoGravity
  ) {
    guard let image = NSImage(contentsOf: imageURL) else {
      Log.warn("playback", "failed to load GIF: \(imageURL.lastPathComponent)")
      return
    }
    let imageView = window.attachGIFImageView(image: image, gravity: gravity)

    let entry = GIFPlaybackEntry(window: window, imageView: imageView)
    register(entry, kindLabel: "gif")
  }

  /// Registers a new entry. If an existing entry is present, tears it down before replacing it,
  /// then wires up occlusion tracking and starts playback according to the initial visibility
  /// (shared by video/gif)
  private func register(_ entry: PlaybackEntry, kindLabel: String) {
    let window = entry.window
    let key = Key(beaconUUID: window.beaconUUID, screenKey: window.screenKey)
    if let existing = entries.removeValue(forKey: key) {
      existing.teardown()
    }
    entries[key] = entry

    window.onVisibilityChange = { [weak self, weak entry] visible in
      guard let self, let entry else { return }
      entry.isVisible = visible
      if visible && !self.isGloballyPaused && !self.isPowerSaving {
        entry.play()
      } else {
        entry.pause()
      }
    }

    let startVisible = window.isOnActiveSpace
    entry.isVisible = startVisible
    if startVisible && !isGloballyPaused && !isPowerSaving {
      entry.play()
    }

    Log.info(
      "playback", "started kind=\(kindLabel) beacon=\(window.beaconUUID) screen=\(window.screenKey)"
    )
  }

  func stopPlayback(beaconUUID: UUID) {
    let keysToRemove = entries.keys.filter { $0.beaconUUID == beaconUUID }
    for key in keysToRemove {
      if let entry = entries.removeValue(forKey: key) {
        entry.pause()
        entry.teardown()
      }
    }
    if !keysToRemove.isEmpty {
      Log.info("playback", "stopped beacon=\(beaconUUID)")
    }
  }

  func stopAll() {
    for entry in entries.values {
      entry.pause()
      entry.teardown()
    }
    entries.removeAll()
    Log.info("playback", "stopped all")
  }

  /// Whether a playback entry currently exists for the given (beaconUUID, screenKey).
  /// Because entries can hold only one item per (beaconUUID, screenKey) key (see register),
  /// if duplicate windows compete for the same key, one of them has already been torn down and
  /// holds no playback (a self-healing target). FolderSpaceCoordinator.ensureWindow uses this
  /// to detect that state
  func hasActiveEntry(beaconUUID: UUID, screenKey: String) -> Bool {
    entries[Key(beaconUUID: beaconUUID, screenKey: screenKey)] != nil
  }

  /// State-transition notification from PowerMonitor. Whether we should actually retreat also
  /// takes powerSavingEnabled into account
  private func handlePowerStateChange(_ constrained: Bool) {
    applyPowerSaving(effective: constrained && powerSavingEnabled)
  }

  /// When powerSavingEnabled changes, re-evaluate immediately with the current constrained value
  private func applyEffectivePowerState() {
    applyPowerSaving(effective: powerMonitor.isConstrained && powerSavingEnabled)
  }

  /// Applies only when whether we should actually retreat (= constrained && powerSavingEnabled)
  /// has changed. true = enter power saving, false = release it
  private func applyPowerSaving(effective: Bool) {
    guard effective != isPowerSaving else { return }
    if effective {
      isPowerSaving = true
      for entry in entries.values {
        entry.pause()
        // Retreat to the wallpaper's static beacon image via orderOut (the Engine never
        // re-shows the window on its own)
        entry.window.hide()
        entry.teardown()
      }
      entries.removeAll()
      Log.info("playback", "power saving engaged: all playback retreated to beacon poster")
      onPowerStateChange?()
    } else {
      isPowerSaving = false
      Log.info("playback", "power saving released")
      // Do not re-show anything here. Rebuilding the windows for the current space is done by
      // the caller (SingleVideoController / FolderSpaceCoordinator) via onPowerStateChange
      onPowerStateChange?()
    }
  }
}
