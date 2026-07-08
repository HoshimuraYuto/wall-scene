import AVFoundation
import AppKit

// Controller for single mode (v1). Self-contained handling of one display's
// ".canJoinAllSpaces window + occlusion-driven looped playback".
// In v1, besides videos, images (stills) and GIFs (animated) can also be selected.
// The media kind is determined by MediaKind.classify(url:) and drives the behavior from there on:
// - video: loop playback with AVQueuePlayer + AVPlayerLooper, as before
// - image: simply shows a still image at all times (no player; occlusion handling and
//   power-saving fallback are unnecessary)
// - gif: loops via NSImageView.animates. Occlusion/power saving only toggle animates on/off
//   (a dedicated path because AVFoundation cannot play GIFs)
// This controller plays no part in beacons or space identification (unnecessary because the
// content is shown on all spaces). However, as a Mission Control countermeasure, it does replace
// the wallpaper with a still image of the selected media (see the "Wallpaper still-image
// replacement" section and WallpaperPosterCache for details).
//
// Conventions borrowed from (unchanged):
// - Playback/WallpaperWindow.swift: window level / borderless conventions
// - Playback/PlaybackEngine.swift: AVQueuePlayer + AVPlayerLooper conventions
//
// Additional verification for single-video mode (G-single: GO). Confirmed on real hardware that
// with collectionBehavior = [.canJoinAllSpaces] the content is shown on all spaces while
// occlusionState still tracks actual visibility.

// MARK: - Window

/// Wallpaper window for single mode. Given canJoinAllSpaces so it shows on all spaces
/// (unlike WallpaperWindow.swift, this one must NOT have an empty collectionBehavior)
private final class SingleVideoWindow: NSWindow {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  init(screen: NSScreen) {
    super.init(
      contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    isOpaque = true
    backgroundColor = .black
    ignoresMouseEvents = true
    level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
    collectionBehavior = [.canJoinAllSpaces]
    isReleasedWhenClosed = false
    setFrame(screen.frame, display: false)
  }
}

/// View that exclusively hosts one of: the playback layer (AVPlayerLayer), a still image
/// (poster), or a GIF (animated NSImageView). AppKit always calls setFrameSize when the
/// window/view frame changes, so we ride on it to keep the sublayer/poster tracking bounds
/// (the same handling also lives in layout() so both paths track reliably).
/// GIF frames must preserve aspect ratio, so they are not matched to bounds; the caller
/// (SingleVideoController.updateFrame) recomputes them individually.
private final class SingleVideoHostView: NSView {
  private var posterImageView: NSImageView?
  private var gifImageView: NSImageView?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.cgColor
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.cgColor
  }

  override func layout() {
    super.layout()
    syncContentFrame()
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    syncContentFrame()
  }

  func syncContentFrame() {
    let bounds = self.bounds
    layer?.sublayers?.forEach { $0.frame = bounds }
    posterImageView?.frame = bounds
    // gifImageView is not matched to bounds (the caller sets it individually to keep aspect ratio)
  }

  func setPlayerLayer(_ playerLayer: AVPlayerLayer) {
    clearContent()
    playerLayer.frame = bounds
    layer?.addSublayer(playerLayer)
  }

  /// Shows a still image already rendered to the target size (displayed 1:1, without imageScaling)
  func setPosterImage(_ image: NSImage) {
    clearContent()
    let iv = NSImageView(frame: bounds)
    iv.imageScaling = .scaleNone
    iv.imageAlignment = .alignCenter
    iv.image = image
    addSubview(iv)
    posterImageView = iv
  }

  /// Adds an NSImageView for GIF animation. The caller controls toggling animates on/off
  @discardableResult
  func setGIFImageView(_ image: NSImage, frame: NSRect) -> NSImageView {
    clearContent()
    let iv = NSImageView(frame: frame)
    iv.image = image
    iv.imageScaling = .scaleAxesIndependently
    iv.animates = false
    layer?.masksToBounds = true
    addSubview(iv)
    gifImageView = iv
    return iv
  }

  func clearContent() {
    layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
    posterImageView?.removeFromSuperview()
    posterImageView = nil
    gifImageView?.removeFromSuperview()
    gifImageView = nil
  }
}

// MARK: - Controller

/// Self-contained controller for one display's "single mode". Depending on the media kind,
/// it switches the window's contents and the playback driving method (video/image/gif).
///
/// Whether playback runs (only video/gif qualify; image is always a still so it is out of scope)
/// is determined by the superposition of the following three states (all held as independent
/// state and evaluated together each time in updatePlaybackState()):
/// - occlusion (isVisible): driven by NSWindow.didChangeOcclusionStateNotification. Whether the
///   window is actually visible
/// - global pause (isSuppressed): suppression flag set via pause()/resume(). Independent of
///   occlusion. resume() only "lifts the suppression"; afterwards, whether playback runs again
///   follows the occlusion state
/// - power-saving fallback (isPowerSaving): enterPowerSaving()/exitPowerSaving(). While active,
///   nothing plays regardless of the two states above. For video, the AVPlayer/AVPlayerLooper
///   themselves are released and swapped for a still of the first frame. For gif, only
///   NSImageView.animates is set to false (the image and player themselves are kept).
///   image does nothing since it is a still to begin with
@MainActor
final class SingleVideoController {
  private let screen: NSScreen
  private let videoURL: URL
  private let scaling: ScalingMode
  private let kind: MediaKind
  private let externalChangePrompter: ExternalChangePrompting

  /// Behavior when a manual wallpaper change (external change) is detected. AppControllerV2
  /// rewrites this live as the setting changes
  var externalChangePolicy: ExternalChangePolicy

  private let window: SingleVideoWindow
  private let hostView: SingleVideoHostView

  private var player: AVQueuePlayer?
  private var looper: AVPlayerLooper?
  private var playerLayer: AVPlayerLayer?

  /// The still generated while video is in power-saving fallback, and the original image for
  /// the image kind (kept so it can be re-rendered when the frame changes)
  private var posterSourceImage: NSImage?

  /// Original image for the gif kind (kept so the frame can be recomputed when the frame changes)
  private var gifSourceImage: NSImage?
  private var gifImageView: NSImageView?

  private var occlusionObserver: NSObjectProtocol?
  private var activeSpaceObserver: NSObjectProtocol?
  private var isApplyingWallpaperPoster = false

  private var isVisible = false
  private var isSuppressed = false
  private(set) var isPowerSaving = false
  private var isStarted = false

  /// Residency state for external change detection (ExternalWallpaperChangeDetector). Single mode
  /// has no per-space beacon identification (one shared poster is reused across all spaces), so
  /// instead of folder mode's 60-second polling timer, occlusion changes (Mission Control
  /// opening/closing, wake from sleep, etc. — see handleOcclusionChange) are used as the
  /// opportunity for a "re-check while residing".
  /// isPosterFreshArrival: set to true on every activeSpaceDidChangeNotification
  /// (= represents that the premise "re-checked while staying on the same space" has broken).
  /// wasPosterConfirmedThisResidency: whether the poster was confirmed on the previous check
  ///
  /// While isPosterFreshArrival is true, decide() unconditionally returns .newOrUnvisited
  /// (the same structural constraint as folder mode), so that alone cannot distinguish
  /// "a space genuinely arrived at for the first time" from "freshly returning to a space whose
  /// wallpaper was previously rejected under this policy".
  /// Single mode has no per-space windows (nothing corresponding to folder mode's windows array),
  /// so instead we remember the "paths of rejected wallpapers" in memory (no persistence needed —
  /// avoiding over-engineering), and when a .newOrUnvisited decision is made we match against
  /// this Set to prevent re-overwriting at minimum cost
  /// (see applyWallpaperPosterIfNeeded/handlePosterExternalChange for details)
  private var isPosterFreshArrival = true
  private var wasPosterConfirmedThisResidency = false
  private var pendingExternalChangePrompt = false
  private var rejectedWallpaperPaths: Set<String> = []

  init(
    screen: NSScreen,
    videoURL: URL,
    scaling: ScalingMode,
    externalChangePolicy: ExternalChangePolicy = .ask,
    externalChangePrompter: ExternalChangePrompting
  ) {
    self.screen = screen
    self.videoURL = videoURL
    self.scaling = scaling
    self.externalChangePolicy = externalChangePolicy
    self.externalChangePrompter = externalChangePrompter
    // When classification fails, treat it as a video as before (AppControllerV2.desiredMode has
    // already verified the file exists, so by the time we get here it is most likely a video
    // that merely has an unusual extension/UTType)
    self.kind = MediaKind.classify(url: videoURL) ?? .video
    self.window = SingleVideoWindow(screen: screen)
    self.hostView = SingleVideoHostView(frame: NSRect(origin: .zero, size: screen.frame.size))
    window.contentView = hostView
  }

  /// Creates and shows the window, then starts playback (video/gif) or still display (image)
  func start() {
    guard !isStarted else { return }
    isStarted = true

    switch kind {
    case .video:
      subscribeOcclusion()
      setupPlayer()
      window.orderFrontRegardless()
      isVisible = window.isOnActiveSpace
      updatePlaybackState()
    case .gif:
      subscribeOcclusion()
      setupGIF()
      window.orderFrontRegardless()
      isVisible = window.isOnActiveSpace
      updatePlaybackState()
    case .image:
      setupImage()
      window.orderFrontRegardless()
    }

    // Wallpaper replacement is needed in all cases regardless of kind (canJoinAllSpaces windows
    // are shown shrunken in Mission Control, exposing the actual desktop picture behind them)
    subscribeActiveSpaceChange()
    ensureWallpaperPoster()

    Log.info(
      "singleVideo",
      "start screen=\(Self.screenKey(screen)) kind=\(kind) media=\(videoURL.lastPathComponent)")
  }

  /// Enables suppression via global pause (independent of the occlusion state)
  func pause() {
    guard !isSuppressed else { return }
    isSuppressed = true
    updatePlaybackState()
  }

  /// Lifts the global-pause suppression. Whether playback runs afterwards follows the occlusion state
  func resume() {
    guard isSuppressed else { return }
    isSuppressed = false
    updatePlaybackState()
  }

  /// Power-saving fallback. For video, releases the AVPlayer/Looper and swaps in a still of the
  /// first frame. For gif, just stops the animation (frozen on the first frame). image does nothing
  func enterPowerSaving() {
    guard !isPowerSaving else { return }
    isPowerSaving = true

    switch kind {
    case .video:
      tearDownPlayer()
      Log.info("singleVideo", "Entering power saving screen=\(Self.screenKey(screen))")
      Task { @MainActor [weak self] in
        guard let self else { return }
        let poster = await self.generatePosterImage()
        // Do not apply if power saving was lifted or stop() was called while waiting. isPowerSaving
        // alone cannot detect stop() (stop() does not reset it), so isStarted must be checked too
        guard self.isPowerSaving, self.isStarted else { return }
        guard let poster else {
          Log.warn(
            "singleVideo",
            "Failed to capture the first frame; showing the black background during power saving screen=\(Self.screenKey(self.screen))"
          )
          return
        }
        self.posterSourceImage = poster
        self.applyPosterImage()
      }
    case .gif:
      gifImageView?.animates = false
      Log.info(
        "singleVideo", "Entering power saving (GIF stopped) screen=\(Self.screenKey(screen))")
    case .image:
      break  // Already a still image, so nothing to do
    }
  }

  /// Exit power saving: video rebuilds the player, gif resumes animation according to the
  /// occlusion state. image does nothing
  func exitPowerSaving() {
    guard isPowerSaving else { return }
    isPowerSaving = false

    switch kind {
    case .video:
      posterSourceImage = nil
      setupPlayer()
      updatePlaybackState()
    case .gif:
      updatePlaybackState()
    case .image:
      break
    }
    Log.info("singleVideo", "Exiting power saving screen=\(Self.screenKey(screen))")
  }

  /// Keeps the window and the layer/still/GIF tracking changes to the screen's frame
  func updateFrame() {
    window.setFrame(screen.frame, display: true)
    hostView.frame = NSRect(origin: .zero, size: screen.frame.size)
    hostView.syncContentFrame()

    if let posterSourceImage, kind == .image || (kind == .video && isPowerSaving) {
      hostView.setPosterImage(renderPosterImage(posterSourceImage, fitting: screen.frame.size))
    }
    if kind == .gif, let gifSourceImage {
      let mode: AspectGeometry.Mode = scaling == .fill ? .fill : .fit
      gifImageView?.frame = AspectGeometry.frame(
        forContentSize: gifSourceImage.size, fitting: hostView.bounds, mode: mode)
    }
  }

  /// Closes the window and releases the player. This instance is never reused afterwards
  /// (rebuilding is assumed)
  func stop() {
    if let occlusionObserver {
      NotificationCenter.default.removeObserver(occlusionObserver)
    }
    occlusionObserver = nil
    if let activeSpaceObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(activeSpaceObserver)
    }
    activeSpaceObserver = nil
    tearDownPlayer()
    hostView.clearContent()
    posterSourceImage = nil
    gifSourceImage = nil
    gifImageView = nil
    window.orderOut(nil)
    window.close()
    isStarted = false
    Log.info("singleVideo", "stop screen=\(Self.screenKey(screen))")
  }

  // MARK: - Evaluating playback state

  private func subscribeOcclusion() {
    occlusionObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didChangeOcclusionStateNotification,
      object: window,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in self?.handleOcclusionChange() }
    }
  }

  private func handleOcclusionChange() {
    isVisible = window.occlusionState.contains(.visible)
    updatePlaybackState()
    // The moment we become visible again (Mission Control closed, woke from sleep, etc.) most
    // likely means we came back to the same space without an intervening
    // activeSpaceDidChangeNotification. Use it as an opportunity for a "re-check while residing"
    // and leverage it for detecting external changes (manual wallpaper changes)
    if isVisible {
      ensureWallpaperPoster()
    }
  }

  private func updatePlaybackState() {
    guard !isPowerSaving else { return }
    switch kind {
    case .video:
      guard let player else { return }
      if isVisible && !isSuppressed {
        player.play()
      } else {
        player.pause()
      }
    case .gif:
      gifImageView?.animates = isVisible && !isSuppressed
    case .image:
      break  // Always shows a still, so no state evaluation needed
    }
  }

  // MARK: - Player construction/teardown (video)

  private func setupPlayer() {
    let item = AVPlayerItem(url: videoURL)
    let player = AVQueuePlayer()
    let looper = AVPlayerLooper(player: player, templateItem: item)
    player.isMuted = true
    // Wallpaper playback must not prevent the display from sleeping
    player.preventsDisplaySleepDuringVideoPlayback = false

    let layer = AVPlayerLayer(player: player)
    layer.videoGravity = scaling == .fill ? .resizeAspectFill : .resizeAspect
    hostView.setPlayerLayer(layer)
    hostView.syncContentFrame()

    self.player = player
    self.looper = looper
    self.playerLayer = layer
  }

  private func tearDownPlayer() {
    player?.pause()
    playerLayer?.removeFromSuperlayer()
    looper?.disableLooping()
    looper = nil
    playerLayer = nil
    player = nil
  }

  // MARK: - GIF construction

  private func setupGIF() {
    guard let image = NSImage(contentsOf: videoURL) else {
      Log.warn(
        "singleVideo", "Failed to load GIF screen=\(Self.screenKey(screen)) path=\(videoURL.path)")
      return
    }
    gifSourceImage = image
    let mode: AspectGeometry.Mode = scaling == .fill ? .fill : .fit
    let frame = AspectGeometry.frame(
      forContentSize: image.size, fitting: hostView.bounds, mode: mode)
    gifImageView = hostView.setGIFImageView(image, frame: frame)
  }

  // MARK: - Still image construction (image)

  private func setupImage() {
    guard let image = NSImage(contentsOf: videoURL) else {
      Log.warn(
        "singleVideo", "Failed to load image screen=\(Self.screenKey(screen)) path=\(videoURL.path)"
      )
      return
    }
    posterSourceImage = image
    hostView.setPosterImage(renderPosterImage(image, fitting: screen.frame.size))
  }

  // MARK: - Still image during power saving (video)

  private func applyPosterImage() {
    guard let posterSourceImage else { return }
    hostView.setPosterImage(renderPosterImage(posterSourceImage, fitting: screen.frame.size))
    hostView.syncContentFrame()
  }

  /// Generates the first frame in memory via AVAssetImageGenerator. Returns nil on failure
  /// (leaving the black background)
  private func generatePosterImage() async -> NSImage? {
    let asset = AVURLAsset(url: videoURL)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    do {
      let result = try await generator.image(at: .zero)
      return NSImage(
        cgImage: result.image, size: NSSize(width: result.image.width, height: result.image.height))
    } catch {
      Log.warn(
        "singleVideo",
        "First-frame generation failed video=\(videoURL.lastPathComponent): \(error.localizedDescription)"
      )
      return nil
    }
  }

  /// Renders the source image to a bitmap exactly matching targetSize according to the scaling
  /// mode (fill = scale up and crop / fit = show the whole image without scaling up, with black
  /// bars) — matching the look of AVPlayerLayer's videoGravity.
  /// The actual compositing (fit/fill math, black-bar drawing) is delegated to ScaledImageRenderer
  /// (to share the implementation with the wallpaper baking in WallpaperPosterCache/FrameExtractor).
  private func renderPosterImage(_ image: NSImage, fitting targetSize: CGSize) -> NSImage {
    guard targetSize.width > 0, targetSize.height > 0, image.size.width > 0, image.size.height > 0
    else {
      return image
    }
    var proposedRect = NSRect(origin: .zero, size: image.size)
    guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
    else {
      return image
    }
    let mode: AspectGeometry.Mode = scaling == .fill ? .fill : .fit
    guard let rendered = ScaledImageRenderer.render(cgImage, targetSize: targetSize, mode: mode)
    else {
      return image
    }
    return NSImage(cgImage: rendered, size: targetSize)
  }

  // MARK: - Wallpaper still-image replacement (Mission Control countermeasure)
  //
  // Single mode only overlays a canJoinAllSpaces window and does not change the actual desktop
  // picture (wallpaper), so opening Mission Control reveals whatever wallpaper was set before
  // (e.g., a beacon image from folder-mode days) as is (the window is shown shrunken in
  // Mission Control, exposing the real wallpaper behind it). Following the same idea as folder
  // mode's beacons, we replace the target display's wallpaper with a still of the selected media.
  // NSWorkspace.setDesktopImageURL has the empirically confirmed limitation that it "only affects
  // the currently active space", so we observe activeSpaceDidChangeNotification and convert
  // spaces to the still wallpaper one by one as they are visited (also run once at start()).
  // The original wallpaper is not restored on stop()/leaving the mode (the same non-restoration
  // policy as folder mode).

  private func subscribeActiveSpaceChange() {
    activeSpaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.activeSpaceDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.isPosterFreshArrival = true
        self?.ensureWallpaperPoster()
      }
    }
  }

  /// Sets the current space's wallpaper to the still image of the selected media if it is not
  /// already set to it. If the poster image is not cached yet, WallpaperPosterCache generates it
  /// (with the same media, same scaling, same pixel size, and same mtime, the cache is reused
  /// and nothing is generated). On generation/setting failure, Log.warn and skip, retrying at
  /// the next opportunity (the next space change)
  private func ensureWallpaperPoster() {
    guard !isApplyingWallpaperPoster else { return }
    isApplyingWallpaperPoster = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.isApplyingWallpaperPoster = false }
      guard
        let posterURL = await WallpaperPosterCache.ensurePoster(
          for: self.videoURL,
          kind: self.kind,
          scaling: self.scaling,
          targetPixelSize: Self.pixelSize(for: self.screen),
          directory: Paths.singlePostersDir
        )
      else {
        Log.warn(
          "singleVideo",
          "Failed to generate the wallpaper still image screen=\(Self.screenKey(self.screen)) media=\(self.videoURL.lastPathComponent)"
        )
        return
      }
      // stop() may have been called (e.g. by a mode switch to a new coordinator) while awaiting
      // the poster above; bail before setDesktopImageURL runs for a controller being retired
      guard self.isStarted else { return }
      await self.applyWallpaperPosterIfNeeded(posterURL)
    }
  }

  /// Does nothing if the current space's wallpaper already points to posterURL (avoiding wasteful
  /// re-setting). If it does not match, ExternalWallpaperChangeDetector determines whether this is
  /// a "first application to a new/unvisited space" or an "external change (a manual change by the
  /// user)", and the latter is handled according to externalChangePolicy
  private func applyWallpaperPosterIfNeeded(_ posterURL: URL) async {
    let isFreshArrival = isPosterFreshArrival
    isPosterFreshArrival = false

    // Immediately after the residency switches, we must not carry over the
    // wasPosterConfirmedThisResidency that was confirmed on the previous space (the same
    // residency-reset principle as FolderSpaceCoordinator's lastConfirmedManagedBinding).
    // Carrying it over would cause the next re-check during this residency (occlusion change
    // etc., isFreshArrival=false) to misinterpret the new space's wallpaper mismatch as an
    // externalChangeDetected originating from the previous space, showing the dialog again for
    // a wallpaper that was already rejected. If the poster genuinely matches, it flips right
    // back to true below
    if isFreshArrival {
      wasPosterConfirmedThisResidency = false
    }

    guard let current = NSWorkspace.shared.desktopImageURL(for: screen) else {
      // Temporarily unreadable, e.g., while the wallpaper system is reloading. Do nothing.
      // However, leaving the freshness consumed and wasPosterConfirmedThisResidency stuck at the
      // previous space's true would make an occlusion re-check during this residency misjudge an
      // unvisited space's user wallpaper as an external change (same reason as the analogous path
      // in FolderSpaceCoordinator.performRefresh).
      // Restore the freshness and also reset the residency state to fail safe
      if isFreshArrival {
        isPosterFreshArrival = true
      }
      wasPosterConfirmedThisResidency = false
      return
    }
    if current.standardizedFileURL.path == posterURL.standardizedFileURL.path {
      wasPosterConfirmedThisResidency = true
      return
    }

    let decision = ExternalWallpaperChangeDetector.decide(
      matchesManaged: false,
      isFreshArrival: isFreshArrival,
      wasConfirmedManagedThisResidency: wasPosterConfirmedThisResidency
    )

    switch decision {
    case .matchesManaged:
      break  // Never reached (the matching case already returned early above)
    case .newOrUnvisited:
      // When isFreshArrival, decide() cannot distinguish "a space genuinely arrived at for the
      // first time" from "freshly returning to a space whose wallpaper was previously rejected
      // under this policy" (see the comment above). Match against rejectedWallpaperPaths here to
      // exclude the latter.
      // However, if the policy has been switched to alwaysRebeacon (always restore), the meaning
      // of the setting is to always re-apply regardless of past rejection records, so the
      // rejection records are not consulted
      let currentPath = current.standardizedFileURL.path
      if externalChangePolicy != .alwaysRebeacon, rejectedWallpaperPaths.contains(currentPath) {
        Log.info(
          "singleVideo",
          "Returned to a space with a previously rejected wallpaper; not re-applying screen=\(Self.screenKey(screen))"
        )
      } else {
        // First time applying the poster to this space. Set it immediately, as before
        setPoster(posterURL)
      }
    case .externalChangeDetected:
      await handlePosterExternalChange(
        posterURL, currentImagePath: current.standardizedFileURL.path)
    }
  }

  /// Branching based on externalChangePolicy when an external change (a manual wallpaper change)
  /// is detected. Unlike folder mode, single mode has no persistent "unmanaged" mark
  /// (because there is no per-space identification mechanism at all; a deliberate simplification
  /// to avoid over-engineering). When rejected via leaveUnmanaged/ask, the currentImagePath at
  /// that moment is recorded in rejectedWallpaperPaths (in memory; no persistence needed). This
  /// not only avoids attempting re-application during this residency (so we don't degrade the
  /// experience by trying to overwrite on every check), but also avoids overwriting again when
  /// the user leaves this space and comes back fresh via an intervening
  /// activeSpaceDidChangeNotification (see the .newOrUnvisited branch of
  /// applyWallpaperPosterIfNeeded)
  private func handlePosterExternalChange(_ posterURL: URL, currentImagePath: String) async {
    guard !pendingExternalChangePrompt else { return }

    // If this wallpaper path was already rejected once, do not ask again even if we reached
    // externalChangeDetected without going through a fresh reset (the residency-reset in
    // applyWallpaperPosterIfNeeded above). If the policy has been switched to alwaysRebeacon,
    // the meaning of the setting is to always re-apply regardless of past rejection records,
    // so the rejection records are not consulted (same approach as the .newOrUnvisited branch)
    if externalChangePolicy != .alwaysRebeacon, rejectedWallpaperPaths.contains(currentImagePath) {
      Log.info(
        "singleVideo",
        "Wallpaper path already rejected; skipping the re-prompt screen=\(Self.screenKey(screen))")
      return
    }

    switch externalChangePolicy {
    case .alwaysRebeacon:
      Log.info(
        "singleVideo",
        "External change detected; re-applying the poster screen=\(Self.screenKey(screen)) media=\(videoURL.lastPathComponent)"
      )
      setPoster(posterURL)
    case .leaveUnmanaged:
      Log.info(
        "singleVideo",
        "External change detected; keeping this space's wallpaper as is screen=\(Self.screenKey(screen))"
      )
      wasPosterConfirmedThisResidency = false
      rejectedWallpaperPaths.insert(currentImagePath)
    case .ask:
      pendingExternalChangePrompt = true
      wasPosterConfirmedThisResidency = false
      let accepted = await externalChangePrompter.promptRebeaconAcceptance(
        displayName: screen.localizedName,
        mediaName: videoURL.lastPathComponent
      )
      pendingExternalChangePrompt = false
      // stop() may have fired while the modal was up; bail before setPoster (setDesktopImageURL)
      // runs for a controller being retired
      guard isStarted else { return }
      if accepted {
        setPoster(posterURL)
      } else {
        Log.info(
          "singleVideo",
          "External change prompt response: chose not to manage screen=\(Self.screenKey(screen))")
        rejectedWallpaperPaths.insert(currentImagePath)
      }
    }
  }

  private func setPoster(_ posterURL: URL) {
    do {
      try NSWorkspace.shared.setDesktopImageURL(
        posterURL, for: screen, options: Self.wallpaperPosterOptions(for: scaling))
      wasPosterConfirmedThisResidency = true
      Log.info(
        "singleVideo",
        "Replaced the wallpaper with a still image screen=\(Self.screenKey(screen)) media=\(videoURL.lastPathComponent)"
      )
    } catch {
      Log.warn(
        "singleVideo",
        "Failed to set the wallpaper screen=\(Self.screenKey(screen)) media=\(videoURL.lastPathComponent) error=\(error.localizedDescription)"
      )
    }
  }

  /// Expresses fill/fit via the options of NSWorkspace.setDesktopImageURL (same convention as
  /// BeaconManager.desktopImageOptions: fill = scale up and allow clipping / fit = scale up but
  /// no clipping, with black bars)
  private static func wallpaperPosterOptions(for scaling: ScalingMode) -> [NSWorkspace
    .DesktopImageOptionKey: Any]
  {
    switch scaling {
    case .fill:
      return [
        .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
        .allowClipping: true,
      ]
    case .fit:
      return [
        .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
        .allowClipping: false,
        .fillColor: NSColor.black,
      ]
    }
  }

  private static func screenKey(_ screen: NSScreen) -> String {
    screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")].map { "\($0)" } ?? "unknown"
  }

  /// Output size of the wallpaper poster (in pixels). Multiplying screen.frame.size (points) by
  /// backingScaleFactor (the Retina multiplier) produces a sharp, pixel-exact image
  private static func pixelSize(for screen: NSScreen) -> CGSize {
    let scale = screen.backingScaleFactor
    return CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale)
  }
}
