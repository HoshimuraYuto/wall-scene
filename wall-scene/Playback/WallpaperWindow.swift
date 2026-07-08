import AVFoundation
import AppKit

/// NSView that hosts the wallpaper video layer. Keeps sublayers tracking its bounds.
final class PlayerHostView: NSView {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    wantsLayer = true
  }

  override func layout() {
    super.layout()
    guard let sublayers = layer?.sublayers else { return }
    for sublayer in sublayers {
      sublayer.frame = bounds
    }
  }
}

/// Duration of the base fade used when presenting a window on space arrival. P0-3: to counter
/// flicker when returning from Mission Control, presenting a new window
/// (WallpaperWindowController.show()) must always transition alpha 0→1 over this duration.
/// Customization is reserved as a Pro feature, so the OSS build uses only this fixed value
/// (no settings UI is added).
enum WallpaperFadeMetrics {
  static let duration: TimeInterval = 0.35
}

/// Borderless window that sits permanently just below the desktop icons and just above the
/// wallpaper. (Per Phase 0 measurements, collectionBehavior must stay empty: adding .stationary
///  makes occlusionState never become .visible, which breaks occlusion-driven playback.)
final class WallpaperWindow: NSWindow {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  init(screen: NSScreen) {
    super.init(
      contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    isOpaque = true
    backgroundColor = .black
    ignoresMouseEvents = true
    level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
    collectionBehavior = []
    isReleasedWhenClosed = false
    setFrame(screen.frame, display: false)
  }
}

/// Controller responsible for creating a WallpaperWindow, controlling its visibility, and
/// observing its occlusion state.
@MainActor
final class WallpaperWindowController: NSObject, WallpaperWindowControlling {
  let beaconUUID: UUID
  let screenKey: String
  var onVisibilityChange: ((Bool) -> Void)?

  private let window: WallpaperWindow
  private let hostView: PlayerHostView
  private var isSubscribed = false

  init(beaconUUID: UUID, screen: NSScreen) {
    self.beaconUUID = beaconUUID
    self.screenKey = WallpaperWindowController.makeScreenKey(screen)
    let window = WallpaperWindow(screen: screen)
    let hostView = PlayerHostView(frame: screen.frame)
    window.contentView = hostView
    self.window = window
    self.hostView = hostView
    super.init()

    // Do not order the window in at this point (it stays hidden until the caller invokes show()).
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleOcclusionChange),
      name: NSWindow.didChangeOcclusionStateNotification,
      object: window
    )
    isSubscribed = true
  }

  var isOrderedIn: Bool { window.isVisible }
  var isOnActiveSpace: Bool { window.isOnActiveSpace }

  func attach(playerLayer: AVPlayerLayer) {
    playerLayer.frame = hostView.bounds
    hostView.layer?.addSublayer(playerLayer)
  }

  /// For GIF animation. Places the image within the bounds as fill/fit while preserving aspect
  /// ratio. Fill is expressed by "scaling the image up so it overflows the host view's bounds and
  /// clipping it with masksToBounds" (NSImageView itself has no way to specify an equivalent of
  /// AVLayerVideoGravity.resizeAspectFill). Since this window is fixed to screen.frame and is
  /// never resized afterwards, the frame is computed only once at creation time (the same
  /// trade-off as the video window not tracking frame changes; see "Known limitations" in the
  /// README).
  func attachGIFImageView(image: NSImage, gravity: AVLayerVideoGravity) -> NSImageView {
    let mode: AspectGeometry.Mode = gravity == .resizeAspectFill ? .fill : .fit
    let imageView = NSImageView(
      frame: AspectGeometry.frame(forContentSize: image.size, fitting: hostView.bounds, mode: mode))
    imageView.image = image
    imageView.imageScaling = .scaleAxesIndependently
    imageView.animates = false
    hostView.layer?.masksToBounds = true
    hostView.addSubview(imageView)
    return imageView
  }

  /// Brings the window to the front. To mitigate the issue where a different medium is briefly
  /// visible in the gap between retiring the old window and reading the beacon (P0-3), the window
  /// is presented with an alpha 0→1 fade-in. Multiple windows can be stacked at the same level
  /// (see WallpaperWindow.init), so calling this while the old window is still around yields a
  /// simple crossfade where the new window fades in on top of the old one.
  func show() {
    window.alphaValue = 0
    window.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { context in
      context.duration = WallpaperFadeMetrics.duration
      window.animator().alphaValue = 1
    }
  }

  func hide() {
    window.orderOut(nil)
  }

  /// This controller cannot be reused after close() (it unsubscribes from the notification).
  func close() {
    hide()
    if isSubscribed {
      NotificationCenter.default.removeObserver(
        self, name: NSWindow.didChangeOcclusionStateNotification, object: window)
      isSubscribed = false
    }
  }

  @objc private func handleOcclusionChange() {
    onVisibilityChange?(window.occlusionState.contains(.visible))
  }

  private static func makeScreenKey(_ screen: NSScreen) -> String {
    guard
      let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    else {
      return "unknown"
    }
    return number.stringValue
  }
}

/// Factory that creates WallpaperWindowController instances.
@MainActor
final class WallpaperWindowControllerFactory: WallpaperWindowFactory {
  func makeWindow(beaconUUID: UUID, screen: NSScreen) -> WallpaperWindowControlling {
    WallpaperWindowController(beaconUUID: beaconUUID, screen: screen)
  }
}
