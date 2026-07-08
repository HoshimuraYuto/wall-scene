import AVFoundation
import AppKit

/// Coordinator responsible for "folder mode" on a single display.
/// It keeps the refresh reentrancy control and the retire pattern, while limiting its scope to a
/// single displayUUID and adding the re-draw logic that kicks in when the interval is exceeded.
@MainActor
final class FolderSpaceCoordinator {
  private let displayUUID: String
  private let folderURL: URL
  private let timing: RotationTiming
  private let beacon: BeaconManaging
  private let playback: PlaybackControlling
  private let windowFactory: WallpaperWindowFactory
  private let bindingStore: SpaceBindingStore
  private let mediaLibrary: MediaLibraryScanning
  private let scaling: ScalingMode
  private let externalChangePrompter: ExternalChangePrompting

  /// Behavior when a manual wallpaper change (external change) is detected. AppControllerV2
  /// rewrites this live in response to settings changes (no recreate needed; same convention as
  /// setPowerSavingEnabled and friends)
  var externalChangePolicy: ExternalChangePolicy

  /// Registry of windows created by this coordinator. Holds only windows belonging to the
  /// screenKey of the display it is responsible for
  private var windows: [WallpaperWindowControlling] = []

  private var isRefreshing = false
  private var refreshPending = false

  private var activeSpaceObserver: NSObjectProtocol?
  private var screenParamsObserver: NSObjectProtocol?
  private var wakeObserver: NSObjectProtocol?
  private var timer: Timer?

  /// The "most recent rotation epoch" that RotationPolicy.needsReassignment bases its decision on.
  /// Set to appLaunchTime in start() when timing is .onLogin (not Date(), so that recreating the
  /// coordinator mid-session — a scaling/timing change, a display reconnect, etc. — does not
  /// re-trigger a mass reassignment for bindings already assigned since the app launched; see
  /// appLaunchTime below), or updated to Date() on every wake when it is .onWake (it is never
  /// updated at other timings and stays .distantPast = has no effect on the decision).
  /// Spaces whose binding.assignedAt is older than this get re-drawn the next time we arrive at /
  /// poll that space (in visit order, not all spaces at once)
  private var lastRotationEpoch: Date = .distantPast

  /// The moment this app process launched, supplied by AppControllerV2 (which captures it once,
  /// at its own init, and passes the same Date to every FolderSpaceCoordinator it ever constructs
  /// during this process's lifetime — including coordinators recreated later due to a mode/scaling
  /// change or a display reconnect). Used as the .onLogin epoch reset target in start() instead of
  /// Date(): using "now" there would make every coordinator recreation (not just an actual app
  /// launch) re-arm the .onLogin epoch and mark every space stale, contradicting the "on login
  /// only" setting (see the P0 bug this fixed). Because it is the same fixed value across
  /// recreations within one process run, bindings assigned earlier in the same run are already
  /// newer than it and are correctly left untouched
  private let appLaunchTime: Date

  /// Whether stop() has been called. Set in stop() and checked at the top of performRefresh() and
  /// right after each `await` resumption that leads to a side effect (setBeacon / bindingStore
  /// writes / window creation), so that a refresh already in flight when stop() is called cannot
  /// complete those side effects for a coordinator that has already been retired (the same failure
  /// shape as the past memory-exhaustion incident: a zombied coordinator's Task finishing
  /// ensureWindow/setBeacon/upsert after stop() leaks a window + AVQueuePlayer per re-creation)
  private var isStopped = false

  /// Residency state used by external-change detection (ExternalWallpaperChangeDetector).
  ///
  /// For spaces assigned a video/gif, performRefresh() preferentially uses "does a window for the
  /// currently active space still remain on this screen (the windows array)" as stronger evidence
  /// than isFreshArrival (see the comment at that spot). The spaceMayHaveChanged /
  /// lastConfirmedManagedBinding below remain necessary as fallbacks for when that window-based
  /// check is unavailable (image-media spaces = no window; right after an app restart = windows
  /// not restored yet):
  /// spaceMayHaveChanged: set to true on every activeSpaceDidChangeNotification / screen-layout
  /// change. Read at the top of performRefresh(), consumed as isFreshArrival, and reset to false
  /// (represents "did a space switch happen since the last performRefresh completed").
  /// lastConfirmedManagedBinding: the binding from the previous check within the same residency
  /// when it was under management (matchesManaged, or an external change confirmed by the
  /// window-based check).
  /// pendingExternalChangePromptUUIDs: beaconUUIDs awaiting an answer under the ask policy
  /// (deduplication so we never show the dialog twice)
  private var spaceMayHaveChanged = true
  private var lastConfirmedManagedBinding: SpaceBinding?
  private var pendingExternalChangePromptUUIDs: Set<UUID> = []

  /// The recorded "suspicion" used for the two-consecutive-match debounce of the window-based
  /// external-change check (inside performRefresh below). See
  /// ExternalWallpaperChangeDetector.WindowSuspicion.decide. On any branch that breaks the
  /// single-residency context (binding confirmed / already decided unmanaged / responsible display
  /// gone, etc.) it is reset to nil each time, so we never falsely confirm across unrelated
  /// contexts.
  /// Normally, right after recording the first .pending observation,
  /// scheduleWindowSuspicionRecheck() schedules a recheck about 2 seconds later, so the second
  /// observation arrives on the spot (~2s later). The existing 60-second polling remains only as a
  /// fallback in case that dedicated scheduling is somehow missed
  private var pendingWindowSuspicion: ExternalWallpaperChangeDetector.WindowSuspicion.Observation?
  /// "Recheck already scheduled" flag for pendingWindowSuspicion. Guard against scheduling the
  /// Task twice. The Task itself resets this to false right before it finishes its ~2-second sleep
  /// and calls refresh(), so it is true only while sleeping (= multiple concurrent recheck Tasks
  /// are never in flight for the same suspicion)
  private var pendingWindowSuspicionRecheckScheduled = false

  /// The recorded suspicion used for the two-consecutive-match debounce of "there is no window at
  /// all on this screen". See ExternalWallpaperChangeDetector.NoResidentWindowSuspicion.decide.
  /// Same idea as pendingWindowSuspicion: reset to nil on any branch that breaks the
  /// single-residency context. Also cleared when the window-based check (a residentWindow was
  /// found) proceeds, since this suspicion becomes irrelevant then
  private var pendingNoResidentWindowSuspicion:
    ExternalWallpaperChangeDetector.NoResidentWindowSuspicion.Observation?
  /// Recheck-scheduled flag for pendingNoResidentWindowSuspicion.
  /// Same role as pendingWindowSuspicionRecheckScheduled
  private var pendingNoResidentWindowSuspicionRecheckScheduled = false

  init(
    displayUUID: String,
    folderURL: URL,
    timing: RotationTiming,
    beacon: BeaconManaging,
    playback: PlaybackControlling,
    windowFactory: WallpaperWindowFactory,
    bindingStore: SpaceBindingStore,
    mediaLibrary: MediaLibraryScanning,
    scaling: ScalingMode,
    externalChangePolicy: ExternalChangePolicy = .ask,
    externalChangePrompter: ExternalChangePrompting,
    appLaunchTime: Date
  ) {
    self.displayUUID = displayUUID
    self.folderURL = folderURL
    self.timing = timing
    self.beacon = beacon
    self.playback = playback
    self.windowFactory = windowFactory
    self.bindingStore = bindingStore
    self.mediaLibrary = mediaLibrary
    self.scaling = scaling
    self.externalChangePolicy = externalChangePolicy
    self.externalChangePrompter = externalChangePrompter
    self.appLaunchTime = appLaunchTime
  }

  func start() {
    activeSpaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.activeSpaceDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.spaceMayHaveChanged = true
        self?.refresh()
      }
    }
    screenParamsObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.spaceMayHaveChanged = true
        self?.refresh()
      }
    }
    // .onWake: update the epoch on every wake so subsequent arrivals/polls trigger a re-draw.
    // Prompting the currently visible space with refresh() too means it may be re-drawn
    // immediately on wake (as specified)
    wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, case .onWake = self.timing else { return }
        Log.info("folderCoordinator", "updating rotation epoch on wake display=\(self.displayUUID)")
        self.lastRotationEpoch = Date()
        self.refresh()
      }
    }
    // For interval-exceeded checks on the current space. Lets us re-draw periodically even while
    // no space switches happen (for .onLogin/.onWake too, this is the re-draw trigger when the
    // user keeps staying on a space without switching after the epoch was updated)
    let pollTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in self?.refresh() }
    }
    RunLoop.main.add(pollTimer, forMode: .common)
    timer = pollTimer

    // .onLogin: reset the epoch to appLaunchTime (the actual app-launch moment, not "now" — see
    // the doc comment on appLaunchTime). Bindings assigned in a previous process run are
    // necessarily older than appLaunchTime, so each is re-drawn exactly once on the next visit.
    // Because appLaunchTime stays fixed across coordinator recreations within the same process
    // run, a scaling/timing change or display reconnect that recreates this coordinator does not
    // spuriously mark bindings assigned earlier in this same run as stale
    if case .onLogin = timing {
      lastRotationEpoch = appLaunchTime
    }

    Log.info(
      "folderCoordinator", "start display=\(displayUUID) folder=\(folderURL.path) timing=\(timing)")
    refresh()
  }

  func stop() {
    // Set first so any refresh()/performRefresh() Task still in flight observes it as soon as it
    // next checks (at the top of performRefresh, and after each await resumption inside it and
    // performAssignment/regenerateBeacon/handleExternalChange) and bails out before touching
    // setBeacon / bindingStore / windows for a coordinator that is being retired right now
    isStopped = true

    if let activeSpaceObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(activeSpaceObserver)
    }
    if let screenParamsObserver {
      NotificationCenter.default.removeObserver(screenParamsObserver)
    }
    if let wakeObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
    }
    activeSpaceObserver = nil
    screenParamsObserver = nil
    wakeObserver = nil
    timer?.invalidate()
    timer = nil

    for window in windows {
      playback.stopPlayback(beaconUUID: window.beaconUUID)
      window.close()
    }
    windows.removeAll()
    Log.info("folderCoordinator", "stop display=\(displayUUID)")
  }

  /// Makes the assignments of all spaces eligible for re-draw "right now" (the shared entry point
  /// for the automatic reassignment on folder-path change and the manual "Reassign wallpapers"
  /// button in settings).
  /// Same semantics shape as .onWake: advancing the rotation epoch to now marks every binding
  /// stale in one shot; the currently visible space is re-drawn immediately by the refresh() right
  /// after, and the other spaces are re-drawn one by one on their next visit (or via the 60-second
  /// polling)
  /// (doing all spaces at once is impossible because the wallpaper API only affects the active
  /// space).
  /// Does not touch spaceMayHaveChanged (setting it would pointlessly reset the external-change
  /// detection debounce (WindowSuspicion's two consecutive observations).
  /// isUnmanaged spaces stay excluded because performRefresh returns early for them)
  func reassignNow() {
    Log.info(
      "folderCoordinator",
      "updating rotation epoch due to immediate reassignment request display=\(displayUUID)")
    lastRotationEpoch = Date()
    refresh()
  }

  /// Re-resolves the responsible display. On reentry, holds at most one pending request and
  /// re-runs after the current pass completes
  func refresh() {
    // Once stopped, this coordinator is retired for good (AppControllerV2 never resumes a stopped
    // instance; it always constructs a fresh one), so no new refresh cycle should start. A refresh
    // already in flight is separately guarded inside performRefresh
    guard !isStopped else { return }
    if isRefreshing {
      refreshPending = true
      return
    }
    isRefreshing = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      await self.performRefresh()
      self.isRefreshing = false
      if self.refreshPending {
        self.refreshPending = false
        self.refresh()
      }
    }
  }

  /// Called right after recording pendingWindowSuspicion as .pending. Fires refresh() once about
  /// 2 seconds later so WindowSuspicion's "two consecutive observations" completes quickly instead
  /// of waiting for the 60-second polling (item1). Does nothing if a recheck of the same kind is
  /// already sleeping (prevents double scheduling)
  private func scheduleWindowSuspicionRecheck() {
    guard !pendingWindowSuspicionRecheckScheduled else { return }
    pendingWindowSuspicionRecheckScheduled = true
    Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      self?.pendingWindowSuspicionRecheckScheduled = false
      self?.refresh()
    }
  }

  /// The pendingNoResidentWindowSuspicion counterpart of scheduleWindowSuspicionRecheck (item2)
  private func scheduleNoResidentWindowSuspicionRecheck() {
    guard !pendingNoResidentWindowSuspicionRecheckScheduled else { return }
    pendingNoResidentWindowSuspicionRecheckScheduled = true
    Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      self?.pendingNoResidentWindowSuspicionRecheckScheduled = false
      self?.refresh()
    }
  }

  private func performRefresh() async {
    // stop() may have been called between refresh() scheduling this Task and it actually running
    // (or, further down, while awaiting beacon.currentBeaconUUID / performAssignment /
    // regenerateBeacon / handleExternalChange). Bail out before touching setBeacon / bindingStore /
    // windows for a coordinator that is being retired (see the isStopped doc comment)
    guard !isStopped else { return }

    // Whether a space switch (or a screen-layout change) happened since the last performRefresh
    // completed. Consumed as isFreshArrival by ExternalWallpaperChangeDetector.decide
    let isFreshArrival = spaceMayHaveChanged
    spaceMayHaveChanged = false

    // Right after residency switches, the lastConfirmedManagedBinding confirmed on the previous
    // space must not be carried over. Carrying it over would make the new space's non-beacon
    // wallpaper (when the window-based check is unavailable) be misidentified as an external
    // change against the previous space's binding, and that media would get baked onto the new
    // space.
    // If the space really is under management, the (a)/(b) branches below re-set
    // lastConfirmedManagedBinding immediately once they confirm the beacon match, so clearing it
    // here is safe
    if isFreshArrival {
      lastConfirmedManagedBinding = nil
    }

    let matchingScreen = NSScreen.screens.first { $0.stableDisplayUUID == displayUUID }

    retireOrphanWindows(currentScreenKey: matchingScreen.map(Self.screenKey(for:)))

    guard let screen = matchingScreen else {
      // The responsible display is not found (disconnected, etc.). Orphan windows were already
      // collected above, so do nothing
      lastConfirmedManagedBinding = nil
      pendingWindowSuspicion = nil
      pendingNoResidentWindowSuspicion = nil
      return
    }

    let screenKey = Self.screenKey(for: screen)
    let currentUUID = await beacon.currentBeaconUUID(on: screen)
    guard !isStopped else { return }

    retireStaleWindows(screenKey: screenKey, currentUUID: currentUUID)

    if let currentUUID, let binding = bindingStore.binding(for: currentUUID) {
      // The current wallpaper is a known managed one (the beacon has a binding)
      lastConfirmedManagedBinding = binding
      pendingWindowSuspicion = nil
      pendingNoResidentWindowSuspicion = nil
      if RotationPolicy.needsReassignment(
        binding: binding, timing: timing, now: Date(), lastRotationEpoch: lastRotationEpoch)
      {
        // (b-2) Re-draw needed (interval exceeded, or first visit after the epoch was updated at
        // login / on wake)
        await performAssignment(
          screen: screen, screenKey: screenKey, excludingPath: binding.videoPath,
          previousBinding: binding)
      } else {
        // (b-1) No re-draw needed. However, if the scaling/screen pixel size recorded on the
        // binding disagrees with the current one (or is nil = an old-generation beacon), the
        // beacon must be re-rendered with the same media (otherwise switching fit/fill would never
        // change the appearance of existing spaces).
        // The same re-render is also needed when beacon-*.heic has actually gone missing from
        // disk (e.g. due to a past false positive) (self-healing: regenerate it with the same
        // media on the next visit to this space instead of leaving a black screen)
        let targetPixelSize = Self.targetPixelSize(for: screen)
        let beaconFileURL = Paths.beaconsDir.appendingPathComponent(
          "beacon-" + binding.beaconUUID.uuidString + ".heic")
        let beaconFileExists = FileManager.default.fileExists(atPath: beaconFileURL.path)
        if BeaconRegenerationPolicy.needsRegeneration(
          binding: binding, currentScaling: scaling, currentPixelSize: targetPixelSize,
          beaconFileExists: beaconFileExists)
        {
          if !beaconFileExists {
            Log.warn(
              "folderCoordinator",
              "beacon HEIC not found on disk, re-rendering as self-healing uuid=\(binding.beaconUUID) path=\(binding.videoPath)"
            )
          }
          await regenerateBeacon(
            binding: binding, screen: screen, screenKey: screenKey, targetPixelSize: targetPixelSize
          )
        } else {
          // No re-render needed. If there is no window, just create one and start playback
          // (images need no window)
          let mediaURL = URL(fileURLWithPath: binding.videoPath)
          if let kind = MediaKind.classify(url: mediaURL) {
            switch kind {
            case .video, .gif:
              ensureWindow(
                screenKey: screenKey, screen: screen, beaconUUID: currentUUID, kind: kind,
                mediaURL: mediaURL)
            case .image:
              break  // The wallpaper (beacon) itself is the finished product; no window is made
            }
          } else {
            Log.warn(
              "folderCoordinator",
              "cannot classify media kind, not creating a window uuid=\(currentUUID) path=\(binding.videoPath)"
            )
          }
        }
      }
      return
    }

    if currentUUID != nil {
      // (c) There is a UUID but the binding is unknown (stale data, etc.). Since it is in beacon
      // form, treat it as an internal data mismatch rather than a manual change by the user, and
      // reassign it the same way as a re-draw, as before
      lastConfirmedManagedBinding = nil
      pendingWindowSuspicion = nil
      pendingNoResidentWindowSuspicion = nil
      await performAssignment(screen: screen, screenKey: screenKey, excludingPath: nil)
      return
    }

    // currentUUID == nil: the current wallpaper is not in the known beacon form.
    // Decide whether this is a "new/unvisited space" or a "space we used to manage whose wallpaper
    // was changed manually (external change)"
    guard let currentImageURL = NSWorkspace.shared.desktopImageURL(for: screen) else {
      // Temporarily unreadable, e.g. while the wallpaper system is reloading. Do nothing
      // (following the existing resilience policy).
      // However, if this early return leaves freshness consumed and lastConfirmedManagedBinding
      // still holding the previous space's value, the next poll (isFreshArrival=false) would
      // misjudge the post-switch space's non-beacon wallpaper as an external change (the scenario:
      // space A confirmed managed -> switch to B -> momentary nil right after).
      // Restore freshness and also reset the residency state to fail safe
      if isFreshArrival {
        spaceMayHaveChanged = true
      }
      lastConfirmedManagedBinding = nil
      pendingWindowSuspicion = nil
      pendingNoResidentWindowSuspicion = nil
      return
    }
    let currentImagePath = currentImageURL.standardizedFileURL.path

    let unmanagedPaths = bindingStore.bindings(displayUUID: displayUUID).compactMap {
      $0.isUnmanaged ? $0.unmanagedImagePath : nil
    }
    if ExternalWallpaperChangeDetector.isKnownUnmanagedPath(
      currentImagePath, unmanagedPaths: unmanagedPaths)
    {
      // A space already decided to be "unmanaged". Show no window and do not reassign
      lastConfirmedManagedBinding = nil
      pendingWindowSuspicion = nil
      pendingNoResidentWindowSuspicion = nil
      return
    }

    // Window-based check. Spaces assigned a video/GIF keep a window with a beaconUUID resident
    // (see ensureWindow), so the very fact that "a window for the currently active space still has
    // residency on this screen" is strong evidence that "we used to manage this space".
    // isOnActiveSpace stays true even while parked for power saving (isOrderedIn=false)
    // (see the comment near line 441 in ensureWindow; verified on real hardware), so we look at
    // isOnActiveSpace only.
    //
    // However, isOnActiveSpace can momentarily return true for the old space's window during a
    // space switch / Mission Control transition, and desktopImageURL can also return a transient
    // value mid-transition.
    // Confirming on a single observation would wrongly trigger regenerateBeacon (re-baking the
    // same media onto a different space) or markUnmanaged (deleting the correct space's beacon
    // HEIC = black screen), so ExternalWallpaperChangeDetector.WindowSuspicion inserts a debounce:
    // "confirm only when the same window and the same wallpaper path are observed twice in a row
    // with no space switch in between". The second observation is scheduled by
    // scheduleWindowSuspicionRecheck() itself about 2 seconds later, so confirmation normally
    // takes about 2 seconds (the existing 60-second polling functions only as a fallback in case
    // that dedicated scheduling is missed).
    //
    // Known limitations: image-media spaces (the finished wallpaper itself is the beacon, so
    // there is no window) and right after an app restart (windows not restored yet) fall outside
    // this check and fall back to the isFreshArrival-based decide() as before (= treated as a
    // new/unvisited space; though via NoResidentWindowSuspicion below, "no window" itself is also
    // confirmed twice in a row to rule out a transient state before assigning)
    if let residentWindow = windows.first(where: { $0.screenKey == screenKey && $0.isOnActiveSpace }
    ),
      let residentBinding = bindingStore.binding(for: residentWindow.beaconUUID)
    {
      // Since a window was found, any "no window" debounce accumulated up to just now has become
      // irrelevant (if anything, that "no window" observation itself was likely a transient
      // error). Discard it to avoid confusion
      pendingNoResidentWindowSuspicion = nil
      let observation = ExternalWallpaperChangeDetector.WindowSuspicion.Observation(
        windowID: ObjectIdentifier(residentWindow),
        imagePath: currentImagePath
      )
      switch ExternalWallpaperChangeDetector.WindowSuspicion.decide(
        priorSuspicion: pendingWindowSuspicion,
        newObservation: observation,
        spaceChangeObservedSinceLastCheck: isFreshArrival
      ) {
      case .pending(let recorded):
        // First observation (or a restart after a reset). Do not confirm on a single one; wait
        // for the reconfirmation by the recheck ~2 seconds later (with the polling up to 60
        // seconds later as fallback).
        // Do not mark this residency "confirmed managed" yet
        pendingWindowSuspicion = recorded
        scheduleWindowSuspicionRecheck()
        return
      case .confirmed:
        // The same window and the same wallpaper path were observed twice in a row with no space
        // switch in between. Safe to confirm as an external change
        pendingWindowSuspicion = nil
        lastConfirmedManagedBinding = residentBinding
        await handleExternalChange(
          binding: residentBinding, screen: screen, screenKey: screenKey,
          currentImagePath: currentImagePath)
        return
      }
    }
    pendingWindowSuspicion = nil

    let decision = ExternalWallpaperChangeDetector.decide(
      matchesManaged: false,
      isFreshArrival: isFreshArrival,
      wasConfirmedManagedThisResidency: lastConfirmedManagedBinding != nil
    )

    switch decision {
    case .matchesManaged:
      break  // Unreachable (matchesManaged was already handled by the branch above)
    case .newOrUnvisited:
      // (d) Candidate new/unvisited space. However, the "no window" observation itself can be a
      // transient error right after a space switch (the symmetric problem to isOnActiveSpace's
      // transient false; see the NoResidentWindowSuspicion comment), so insert the same
      // two-consecutive debounce as WindowSuspicion before doing a fresh random assignment
      lastConfirmedManagedBinding = nil
      let observation = ExternalWallpaperChangeDetector.NoResidentWindowSuspicion.Observation(
        imagePath: currentImagePath)
      switch ExternalWallpaperChangeDetector.NoResidentWindowSuspicion.decide(
        priorSuspicion: pendingNoResidentWindowSuspicion,
        newObservation: observation,
        spaceChangeObservedSinceLastCheck: isFreshArrival
      ) {
      case .pending(let recorded):
        // First observation (or a restart after a reset). Do not assign on a single one; wait for
        // the recheck ~2 seconds later (the ~2-second delay in assigning a new space is accepted
        // as specified)
        pendingNoResidentWindowSuspicion = recorded
        scheduleNoResidentWindowSuspicionRecheck()
      case .confirmed:
        // The same non-beacon wallpaper path with no window was observed twice in a row with no
        // space switch in between. Safe to do a fresh random assignment as the normal path
        pendingNoResidentWindowSuspicion = nil
        await performAssignment(screen: screen, screenKey: screenKey, excludingPath: nil)
      }
    case .externalChangeDetected:
      pendingNoResidentWindowSuspicion = nil
      guard let binding = lastConfirmedManagedBinding else { return }  // fail safe (theoretically unreachable)
      await handleExternalChange(
        binding: binding, screen: screen, screenKey: screenKey, currentImagePath: currentImagePath)
    }
  }

  // MARK: - Handling external changes (manual wallpaper changes)

  /// Branches on ExternalChangePolicy when an external change is detected. For ask, beaconUUIDs
  /// awaiting an answer are deduplicated via pendingExternalChangePromptUUIDs so the dialog is
  /// never shown twice
  private func handleExternalChange(
    binding: SpaceBinding, screen: NSScreen, screenKey: String, currentImagePath: String
  ) async {
    guard !pendingExternalChangePromptUUIDs.contains(binding.beaconUUID) else { return }

    switch externalChangePolicy {
    case .alwaysRebeacon:
      Log.info(
        "folderCoordinator",
        "external change detected, re-beaconing automatically display=\(displayUUID) uuid=\(binding.beaconUUID)"
      )
      let targetPixelSize = Self.targetPixelSize(for: screen)
      await regenerateBeacon(
        binding: binding, screen: screen, screenKey: screenKey, targetPixelSize: targetPixelSize,
        preserveOldBeaconFile: true)

    case .leaveUnmanaged:
      Log.info(
        "folderCoordinator",
        "external change detected, marking this space unmanaged display=\(displayUUID) uuid=\(binding.beaconUUID)"
      )
      markUnmanaged(binding: binding, currentImagePath: currentImagePath, screenKey: screenKey)

    case .ask:
      pendingExternalChangePromptUUIDs.insert(binding.beaconUUID)
      lastConfirmedManagedBinding = nil  // Not considered managed until an answer arrives
      // Never overwrite silently = also retract the window until an answer arrives (non-restore
      // policy: the original wallpaper is not saved).
      // Retract only the window for the binding.beaconUUID targeted by this dialog, not the whole
      // screenKey (do not drag in playback of unrelated other spaces on the same display.
      // Dragging them in was the cause of the real-hardware bug "videos of unrelated spaces
      // disappear while the modal is shown")
      retireWindow(screenKey: screenKey, beaconUUID: binding.beaconUUID)
      let mediaName = (binding.videoPath as NSString).lastPathComponent
      let accepted = await externalChangePrompter.promptRebeaconAcceptance(
        displayName: screen.localizedName, mediaName: mediaName)
      pendingExternalChangePromptUUIDs.remove(binding.beaconUUID)
      // stop() may have fired while the modal was up (the user can leave it open a long time);
      // bail before regenerateBeacon/markUnmanaged/refresh run for a coordinator being retired
      guard !isStopped else { return }

      // Staleness guard: even though the modal (NSAlert.runModal) blocks synchronously, the user
      // may still switch spaces or change the wallpaper again before responding. In that case, the
      // currentImagePath at detection time (the parameter) and the actual wallpaper path at
      // response time disagree. Applying regenerateBeacon/markUnmanaged while they disagree would
      // re-beacon an unrelated space, or mark a space other than the actually changed one as
      // unmanaged (a bug confirmed on real hardware). Regardless of the value of accepted, if they
      // disagree do nothing and let re-evaluation happen from the current actual state
      let latestImagePath = NSWorkspace.shared.desktopImageURL(for: screen)?.standardizedFileURL
        .path
      guard let latestImagePath, latestImagePath == currentImagePath else {
        Log.info(
          "folderCoordinator",
          "state changed before the modal was answered, skipping the external-change response display=\(displayUUID) uuid=\(binding.beaconUUID)"
        )
        spaceMayHaveChanged = true
        refresh()
        return
      }

      if accepted {
        Log.info(
          "folderCoordinator",
          "external change response: re-beacon accepted display=\(displayUUID) uuid=\(binding.beaconUUID)"
        )
        let targetPixelSize = Self.targetPixelSize(for: screen)
        await regenerateBeacon(
          binding: binding, screen: screen, screenKey: screenKey, targetPixelSize: targetPixelSize,
          preserveOldBeaconFile: true)
      } else {
        Log.info(
          "folderCoordinator",
          "external change response: leave unmanaged chosen display=\(displayUUID) uuid=\(binding.beaconUUID)"
        )
        markUnmanaged(binding: binding, currentImagePath: currentImagePath, screenKey: screenKey)
      }
    }
  }

  /// Marks the binding as "unmanaged" so that no window is shown and no reassignment happens on
  /// subsequent arrivals. The user's wallpaper (currentImagePath) is respected as is; it is
  /// neither overwritten nor saved (consistent with the non-restore policy).
  ///
  /// The old beacon HEIC is not deleted here. If the path that led here (including the
  /// window-based suspicion check and its confirmation) has by any chance confused spaces,
  /// deleting it would remove a HEIC that another space actually references, causing a black
  /// screen (a bug confirmed on real hardware). Cleaning up orphan HEICs is deferred to a separate
  /// P2 backlog item; here "do not delete" takes priority.
  ///
  /// Window collection is also narrowed to only the binding.beaconUUID window, not the whole
  /// screenKey (same reason as the .ask branch of handleExternalChange: do not drag in playback of
  /// unrelated other spaces on the same display)
  private func markUnmanaged(binding: SpaceBinding, currentImagePath: String, screenKey: String) {
    var updated = binding
    updated.isUnmanaged = true
    updated.unmanagedImagePath = currentImagePath
    bindingStore.upsert(updated)
    retireWindow(screenKey: screenKey, beaconUUID: binding.beaconUUID)
  }

  /// Picks one media file at random from the folder (excluding the current media if possible),
  /// issues a new beacon, and assigns it.
  /// Never crashes: if the folder is empty / the scan fails / beacon image generation fails /
  /// setting the beacon fails, it only calls Log.warn.
  ///
  /// - Parameter previousBinding: the binding being replaced by this reassignment (the (b-2)
  ///   rotation path in performRefresh), if any. When present, the old entry is removed from
  ///   bindingStore and the old beacon-<uuid>.heic file is deleted after the new beacon has been
  ///   applied successfully, following the same cleanup pattern as regenerateBeacon (see the
  ///   comment there). Callers that have no existing binding to replace ((c) unknown-binding
  ///   reassignment and (d) fresh assignment to a new/unvisited space) pass nil, which skips this
  ///   cleanup entirely (there is nothing to remove yet).
  private func performAssignment(
    screen: NSScreen, screenKey: String, excludingPath: String?,
    previousBinding: SpaceBinding? = nil
  ) async {
    let media = await mediaLibrary.scanPlayableMedia(in: folderURL)
    // stop() may have fired while awaiting the scan above; bail before setBeacon/bindingStore/
    // window side effects run for a coordinator that is being retired (see isStopped doc comment)
    guard !isStopped else { return }
    guard !media.isEmpty else {
      Log.warn("folderCoordinator", "no playable/displayable media in folder: \(folderURL.path)")
      return
    }

    var pool = media
    if let excludingPath, media.count >= 2 {
      let filtered = media.filter { $0.url.path != excludingPath }
      // If filtering produced an empty result (e.g. the current media disappeared from the
      // folder), fall back to the original pool
      pool = filtered.isEmpty ? media : filtered
    }

    guard let chosen = pool.randomElement() else { return }

    let newUUID = UUID()
    // The beacon bakes fit/fill exactly into the screen's pixel size (we do not rely on options;
    // see the comment in ScaledImageRenderer.swift). Multiplying by backingScaleFactor keeps it
    // pixel-exact and sharp
    let targetPixelSize = Self.targetPixelSize(for: screen)
    let mode: AspectGeometry.Mode = scaling == .fill ? .fill : .fit
    do {
      switch chosen.kind {
      case .video:
        _ = try await FrameExtractor.makeBeaconHEIC(
          from: chosen.url, beaconUUID: newUUID, targetPixelSize: targetPixelSize, mode: mode)
      case .gif, .image:
        // For GIFs the first frame, for images the image itself (orientation-corrected) is read
        // via ImageIO
        _ = try await FrameExtractor.makeBeaconHEIC(
          fromImage: chosen.url, beaconUUID: newUUID, targetPixelSize: targetPixelSize, mode: mode)
      }
    } catch {
      Log.warn(
        "folderCoordinator",
        "failed to generate beacon image: \(chosen.url.lastPathComponent) (\(error.localizedDescription))"
      )
      return
    }
    // stop() may have fired while awaiting FrameExtractor above; bail before setBeacon/
    // bindingStore/window side effects run for a coordinator that is being retired
    guard !isStopped else { return }

    do {
      try beacon.setBeacon(newUUID, on: screen, scaling: scaling)
    } catch {
      Log.warn("folderCoordinator", "failed to set beacon: \(error.localizedDescription)")
      return
    }

    let binding = SpaceBinding(
      beaconUUID: newUUID,
      displayUUID: displayUUID,
      videoPath: chosen.url.path,
      assignedAt: Date(),
      scaling: scaling,
      renderedPixelWidth: Int(targetPixelSize.width.rounded()),
      renderedPixelHeight: Int(targetPixelSize.height.rounded())
    )
    // SpaceBindingStore is keyed by beaconUUID, and this reassignment issues a brand-new UUID, so
    // upsert alone would leave the entry for previousBinding's old beaconUUID behind as garbage
    // (same reasoning as regenerateBeacon's cleanup below). Remove it before adding the new one
    if let previousBinding {
      bindingStore.remove(beaconUUID: previousBinding.beaconUUID)
    }
    bindingStore.upsert(binding)

    // Cleanup of the old beacon HEIC file, mirroring regenerateBeacon's cleanup (see the comment
    // there). Only done once the new beacon has been applied successfully above. Failure only
    // leaves garbage behind and is not fatal, so try? is sufficient
    if let previousBinding {
      try? FileManager.default.removeItem(
        at: Paths.beaconsDir.appendingPathComponent(
          "beacon-" + previousBinding.beaconUUID.uuidString + ".heic"))
    }

    // The wallpaper has already switched to the new UUID. For video/gif, fade in the new window
    // first (P0-3: the crossfade that softens the "another media is visible for an instant" gap
    // between retiring the old window and showing the new one), then collect the old window.
    // image has no window of its own, so it may be collected immediately as before
    switch chosen.kind {
    case .video, .gif:
      ensureWindow(
        screenKey: screenKey, screen: screen, beaconUUID: newUUID, kind: chosen.kind,
        mediaURL: chosen.url)
      scheduleRetireStaleWindows(screenKey: screenKey, currentUUID: newUUID)
    case .image:
      retireStaleWindows(screenKey: screenKey, currentUUID: newUUID)
    }

    Log.info(
      "folderCoordinator",
      "reassigned display=\(displayUUID) uuid=\(newUUID) kind=\(chosen.kind) media=\(chosen.url.lastPathComponent)"
    )
  }

  /// When the binding's scaling/screen pixel size is stale (BeaconRegenerationPolicy
  /// .needsRegeneration returned true), re-renders the beacon HEIC with the same media
  /// (binding.videoPath) at the current scaling + screen pixel size and re-applies the wallpaper.
  /// videoPath and assignedAt are preserved (= does not disturb the rotation cycle). The
  /// beaconUUID must be newly issued (both SpaceBindingStore and BeaconManager use beaconUUID as
  /// the file-name/key convention, so swapping only the HEIC under the same UUID risks the change
  /// not taking effect due to caching in the wallpaper system. Follow the same steps as a fresh
  /// assignment).
  /// If generation/setting fails, Log.warn and continue with the old beacon (same resilience
  /// policy as performAssignment).
  ///
  /// - Parameter preserveOldBeaconFile: if true, skips deleting the old beacon HEIC file.
  ///   For the (b-1) re-render driven by a scaling/screen-size change (the caller has already
  ///   confirmed the binding's beacon match, so confusing spaces is structurally impossible),
  ///   false (= delete, as before) is fine; but when coming via handleExternalChange (based on the
  ///   window-based suspicion check, where even after confirmation a theoretical chance of
  ///   confusing spaces remains), pass true so that at worst we never cause a black screen
  private func regenerateBeacon(
    binding: SpaceBinding, screen: NSScreen, screenKey: String, targetPixelSize: CGSize,
    preserveOldBeaconFile: Bool = false
  ) async {
    let mediaURL = URL(fileURLWithPath: binding.videoPath)
    guard let kind = MediaKind.classify(url: mediaURL) else {
      Log.warn(
        "folderCoordinator",
        "cannot classify media kind, cannot re-render beacon uuid=\(binding.beaconUUID) path=\(binding.videoPath)"
      )
      return
    }

    let newUUID = UUID()
    let mode: AspectGeometry.Mode = scaling == .fill ? .fill : .fit
    do {
      switch kind {
      case .video:
        _ = try await FrameExtractor.makeBeaconHEIC(
          from: mediaURL, beaconUUID: newUUID, targetPixelSize: targetPixelSize, mode: mode)
      case .gif, .image:
        _ = try await FrameExtractor.makeBeaconHEIC(
          fromImage: mediaURL, beaconUUID: newUUID, targetPixelSize: targetPixelSize, mode: mode)
      }
    } catch {
      Log.warn(
        "folderCoordinator",
        "failed to re-render beacon image: \(mediaURL.lastPathComponent) (\(error.localizedDescription))"
      )
      return
    }
    // stop() may have fired while awaiting FrameExtractor above; bail before setBeacon/
    // bindingStore/window side effects run for a coordinator that is being retired
    guard !isStopped else { return }

    do {
      try beacon.setBeacon(newUUID, on: screen, scaling: scaling)
    } catch {
      Log.warn("folderCoordinator", "failed to re-set beacon: \(error.localizedDescription)")
      return
    }

    let oldUUID = binding.beaconUUID
    var updated = binding
    updated.beaconUUID = newUUID
    updated.scaling = scaling
    updated.renderedPixelWidth = Int(targetPixelSize.width.rounded())
    updated.renderedPixelHeight = Int(targetPixelSize.height.rounded())
    // SpaceBindingStore is keyed by beaconUUID, so remove the old entry before adding the new one
    // (with upsert alone the old UUID's entry would remain as garbage)
    bindingStore.remove(beaconUUID: oldUUID)
    bindingStore.upsert(updated)

    // Cleanup of the old beacon HEIC file. "beacon-<uuid>.heic" is a convention string used only
    // under the data directory, duplicated from BeaconManager/FrameExtractor (see the comments in
    // both). Failure only leaves garbage behind and is not fatal, so try? is sufficient.
    // Skipped when preserveOldBeaconFile is true (see the doc comment above)
    if !preserveOldBeaconFile {
      try? FileManager.default.removeItem(
        at: Paths.beaconsDir.appendingPathComponent("beacon-" + oldUUID.uuidString + ".heic"))
    }

    Log.info(
      "folderCoordinator",
      "re-rendered beacon display=\(displayUUID) old=\(oldUUID) new=\(newUUID) scaling=\(scaling) kind=\(kind)"
    )

    // The wallpaper has already switched to the new UUID. For the same reason and in the same
    // order as performAssignment, for video/gif start the new window's fade-in while the old
    // window is still present and collect the old window after the fade completes (crossfade).
    // image has no window, so collect immediately
    switch kind {
    case .video, .gif:
      ensureWindow(
        screenKey: screenKey, screen: screen, beaconUUID: newUUID, kind: kind, mediaURL: mediaURL)
      scheduleRetireStaleWindows(screenKey: screenKey, currentUUID: newUUID)
    case .image:
      retireStaleWindows(screenKey: screenKey, currentUUID: newUUID)
    }
  }

  /// The pixel size the beacon is baked for (screen.frame.size × backingScaleFactor).
  /// Extracted because it is used by both performAssignment (fresh assignment) and
  /// regenerateBeacon (the (b-1) re-render decision and execution)
  private static func targetPixelSize(for screen: NSScreen) -> CGSize {
    CGSize(
      width: screen.frame.width * screen.backingScaleFactor,
      height: screen.frame.height * screen.backingScaleFactor)
  }

  /// Creates a window for the target space if none exists and starts playback (never creates one
  /// while power saving).
  /// kind is expected to be .video or .gif only (.image is branched off by the caller).
  ///
  /// Existing-window matching is done solely on (screenKey, beaconUUID) equality (isOnActiveSpace
  /// is not consulted). Since beaconUUID is unique per space, the (screenKey, beaconUUID) pair
  /// should always have at most one entry; but previously the "existence check" for an existing
  /// window itself included isOnActiveSpace, so at moments when isOnActiveSpace briefly returned
  /// false during a space switch / Mission Control transition, ensureWindow misjudged "no window"
  /// and created a second window for the same (screenKey, beaconUUID) — a real-hardware bug
  /// (logs confirmed on real hardware showing 3–4 windows with the same beaconUUID stacked on the
  /// same space). isOnActiveSpace is for checking "the window already exists, but is it currently
  /// frontmost on this space", and is not used to decide whether creation is needed
  /// (its intended use in the branch below that re-shows an isOrderedIn=false window is
  /// unchanged).
  private func ensureWindow(
    screenKey: String, screen: NSScreen, beaconUUID: UUID, kind: MediaKind, mediaURL: URL
  ) {
    guard !playback.isPowerSaving else { return }

    let matches = windows.filter { $0.screenKey == screenKey && $0.beaconUUID == beaconUUID }

    // Self-healing: if multiple windows for the same (screenKey, beaconUUID) have piled up due to
    // the bug above (or some other path), converge to one. Prefer keeping the isOrderedIn
    // (currently displayed) one and collect the rest.
    // PlaybackEngine.entries can only distinguish by (beaconUUID, screenKey), and the caller
    // cannot tell which of the duplicate windows holds the "currently effective playback entry"
    // (see PlaybackEngine.register: the later registration tears down and overwrites the existing
    // entry, so it is not necessarily the isOrderedIn one). Fail safe: first reliably discard the
    // playback entry for this beaconUUID via stopPlayback, then re-attach playback fresh to the
    // surviving window (register tears down any existing entry before replacing it, so this
    // re-attachment carries no risk of double attachment)
    if matches.count > 1 {
      let survivor = matches.first(where: { $0.isOrderedIn }) ?? matches[0]
      let duplicates = matches.filter { $0 !== survivor }
      Log.warn(
        "folderCoordinator",
        "duplicate windows detected, converging to one uuid=\(beaconUUID) screen=\(screenKey) count=\(matches.count)"
      )
      playback.stopPlayback(beaconUUID: beaconUUID)
      for window in duplicates {
        Log.info(
          "folderCoordinator",
          "retire duplicate window (self-healing) uuid=\(beaconUUID) screen=\(screenKey)")
        window.close()
      }
      windows.removeAll { window in duplicates.contains { $0 === window } }
      startPlayback(kind: kind, mediaURL: mediaURL, on: survivor)
      survivor.show()
      return
    }

    if let existing = matches.first {
      if !existing.isOrderedIn {
        // A window still parked by PlaybackEngine.hide() for power saving (isOnActiveSpace stays
        // true but isOrderedIn becomes false; see PlaybackEngine.applyPowerSaving).
        // Resume playback on the same window instead of creating a new one
        Log.info(
          "folderCoordinator",
          "resume hidden window uuid=\(beaconUUID) screen=\(screenKey) kind=\(kind)")
        startPlayback(kind: kind, mediaURL: mediaURL, on: existing)
        existing.show()
        return
      }
      // The window is displayed, but it may have lost its playback entry (the case where, when one
      // of the duplicate windows was collected by the self-healing above or retireStaleWindows
      // etc., PlaybackEngine.entries got swapped and only this window's playback stopped). To
      // avoid leaving a black screen until the next visit/poll, re-attach playback on the spot
      if !playback.hasActiveEntry(beaconUUID: beaconUUID, screenKey: screenKey) {
        Log.info(
          "folderCoordinator",
          "resume playback (entry lost) uuid=\(beaconUUID) screen=\(screenKey) kind=\(kind)")
        startPlayback(kind: kind, mediaURL: mediaURL, on: existing)
      }
      return
    }

    Log.info(
      "folderCoordinator", "ensure window uuid=\(beaconUUID) screen=\(screenKey) kind=\(kind)")
    let window = windowFactory.makeWindow(beaconUUID: beaconUUID, screen: screen)
    windows.append(window)
    startPlayback(kind: kind, mediaURL: mediaURL, on: window)
    window.show()
  }

  /// Attaches video/gif playback to a window (used both for new windows and for reusing an
  /// existing window when resuming from power saving)
  private func startPlayback(kind: MediaKind, mediaURL: URL, on window: WallpaperWindowControlling)
  {
    let gravity: AVLayerVideoGravity = scaling == .fill ? .resizeAspectFill : .resizeAspect
    switch kind {
    case .video:
      playback.startPlayback(videoURL: mediaURL, in: window, gravity: gravity)
    case .gif:
      playback.startGIFPlayback(imageURL: mediaURL, in: window, gravity: gravity)
    case .image:
      Log.warn(
        "folderCoordinator",
        "window creation called for an image (unexpected) uuid=\(window.beaconUUID)")
    }
  }

  /// Collects the old windows after the new window's fade-in (WallpaperFadeMetrics.duration) has
  /// completed. Calling retireStaleWindows immediately would remove the old window before the new
  /// one finishes fading in, reverting to the old instant switch instead of a crossfade, so the
  /// delay is intentional.
  ///
  /// The collection targets are fixed at scheduling time as "the old windows currently being
  /// covered by the crossfade" (the filter condition is identical to retireStaleWindows).
  /// Re-evaluating at fire time would, if the user switched spaces during the delay, wrongly
  /// collect the destination space's healthy window (whose UUID naturally differs), causing a
  /// "disappears for an instant and comes back" flicker
  private func scheduleRetireStaleWindows(screenKey: String, currentUUID: UUID) {
    let stale = windows.filter {
      $0.screenKey == screenKey && $0.isOnActiveSpace && $0.beaconUUID != currentUUID
    }
    guard !stale.isEmpty else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + WallpaperFadeMetrics.duration) { [weak self] in
      guard let self else { return }
      // Windows already collected by another path (retireStaleWindows / retireWindow /
      // retireOrphanWindows) during the delay are gone from windows, so skip them to avoid a
      // double close
      for window in stale where self.windows.contains(where: { $0 === window }) {
        Log.info(
          "folderCoordinator",
          "retire window (crossfade done) uuid=\(window.beaconUUID) screen=\(screenKey)")
        self.playback.stopPlayback(beaconUUID: window.beaconUUID)
        window.close()
      }
      self.windows.removeAll { window in stale.contains { $0 === window } }
    }
  }

  /// Collects windows that linger on the current space but whose uuid disagrees (leftovers from a
  /// space deletion, wallpaper change, etc.).
  /// Does not collect when currentUUID is nil (when desktopImageURL is temporarily unreadable
  /// because the wallpaper system is reloading).
  private func retireStaleWindows(screenKey: String, currentUUID: UUID?) {
    guard let currentUUID else { return }
    let stale = windows.filter {
      $0.screenKey == screenKey && $0.isOnActiveSpace && $0.beaconUUID != currentUUID
    }
    guard !stale.isEmpty else { return }
    for window in stale {
      Log.info("folderCoordinator", "retire window uuid=\(window.beaconUUID) screen=\(screenKey)")
      playback.stopPlayback(beaconUUID: window.beaconUUID)
      window.close()
    }
    windows.removeAll { window in stale.contains { $0 === window } }
  }

  /// Collects only the windows matching both screenKey and beaconUUID. Used when marking a space
  /// unmanaged / putting it on hold for an answer after detecting an external change (explicit
  /// cleanup for situations where retireStaleWindows cannot work because currentUUID is nil).
  /// The difference from the old retireAllWindows, which dragged in the whole screen, is that
  /// windows of other beaconUUIDs on the same screenKey (= the same physical display) — i.e.
  /// videos/GIFs of unrelated other spaces — are never touched (fixes the real-hardware bug where
  /// showing the dialog made videos of unrelated spaces disappear)
  private func retireWindow(screenKey: String, beaconUUID: UUID) {
    let matching = windows.filter { $0.screenKey == screenKey && $0.beaconUUID == beaconUUID }
    guard !matching.isEmpty else { return }
    for window in matching {
      Log.info(
        "folderCoordinator",
        "retire window (external change, single space) uuid=\(window.beaconUUID) screen=\(screenKey)"
      )
      playback.stopPlayback(beaconUUID: window.beaconUUID)
      window.close()
    }
    windows.removeAll { window in matching.contains { $0 === window } }
  }

  /// Collects windows left dangling because the responsible display was disconnected, etc.
  private func retireOrphanWindows(currentScreenKey: String?) {
    let orphans: [WallpaperWindowControlling]
    if let currentScreenKey {
      orphans = windows.filter { $0.screenKey != currentScreenKey }
    } else {
      orphans = windows
    }
    guard !orphans.isEmpty else { return }
    for window in orphans {
      Log.info(
        "folderCoordinator",
        "retire orphan window (screen gone) uuid=\(window.beaconUUID) screen=\(window.screenKey)")
      playback.stopPlayback(beaconUUID: window.beaconUUID)
      window.close()
    }
    windows.removeAll { window in orphans.contains { $0 === window } }
  }

  private static func screenKey(for screen: NSScreen) -> String {
    screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")].map { "\($0)" } ?? "unknown"
  }
}
