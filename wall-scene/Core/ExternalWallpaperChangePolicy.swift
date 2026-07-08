import Foundation

/// Core detection logic for P0-2 "self-healing against manual wallpaper changes".
///
/// Design constraint (a premise you must understand before anything else):
/// NSWorkspace.desktopImageURL(for:) does not return an identifier for the space itself (the
/// public API has no per-space ID). Wall Scene turns this around and uses the wallpaper content
/// itself (the beacon image) to identify a space. Consequently, the moment a space's wallpaper is
/// rewritten by the user's hand, Wall Scene loses the clue (the beacon UUID) that pointed at that
/// space.
///
/// For this reason, the only case in which we can reliably determine "was this space previously
/// managed by us" is when, within the same residency (= a re-check without an intervening
/// activeSpaceDidChangeNotification), the immediately preceding check confirmed the space was
/// under management. In folder mode, FolderSpaceCoordinator's 60-second polling timer provides
/// this "re-check while staying on the space"; in single mode, SingleVideoController uses
/// occlusion changes (opening/closing Mission Control, waking from sleep, etc.) as this
/// opportunity (see the comments on both implementation sides).
///
/// On the other hand, when a space is revisited after leaving it (i.e. with an
/// activeSpaceDidChangeNotification in between), Wall Scene cannot tell whether it is "a new
/// space being visited for the first time" or "a space we used to manage that was manually
/// changed". This is a structural constraint that cannot be avoided as long as we implement with
/// public APIs only; so that folder mode can keep fresh assignment to unvisited spaces working as
/// the normal path, the safe default is to treat indistinguishable cases as a "new/unvisited
/// space" (i.e. not a target of self-healing).
///
/// Note: folder mode mitigates this structural constraint to some extent with the two
/// two-consecutive-observation debounces below: WindowSuspicion (are windows still resident) and
/// NoResidentWindowSuspicion (the very absence of windows). However, even these debounces cannot
/// distinguish, from a new space, an image-media space — for which having no windows is the
/// normal state — that was manually changed while the user was away (because as long as
/// currentUUID matches the binding's beacon, this code path is never reached in the first
/// place). See the comment on NoResidentWindowSuspicion for details
enum ExternalWallpaperChangeDetector {
  /// The decision result
  enum Decision: Equatable {
    /// The current wallpaper matches a known managed target (beacon/poster). It is fine to
    /// continue as usual
    case matchesManaged
    /// Not managed, but can be regarded as a new/unvisited space (not a target of self-healing.
    /// The normal folder fresh assignment / poster application may proceed)
    case newOrUnvisited
    /// Not managed, and it is confirmed that the space was under management until just now
    /// within the same residency. Treat it as an external change by the user (handle it
    /// according to ExternalChangePolicy)
    case externalChangeDetected
  }

  /// - Parameters:
  ///   - matchesManaged: Whether the current wallpaper is a known managed target (the beacon
  ///     UUID has a binding / it matches the poster URL)
  ///   - isFreshArrival: Whether this check is the first one right after a space switch
  ///     (activeSpaceDidChangeNotification etc.). When true, the premise "we re-checked while
  ///     staying on the same space" does not hold, so we cannot distinguish and return the safe
  ///     side (newOrUnvisited)
  ///   - wasConfirmedManagedThisResidency: Whether matchesManaged was true on the previous
  ///     check within the same residency
  static func decide(
    matchesManaged: Bool,
    isFreshArrival: Bool,
    wasConfirmedManagedThisResidency: Bool
  ) -> Decision {
    if matchesManaged {
      return .matchesManaged
    }
    if !isFreshArrival && wasConfirmedManagedThisResidency {
      return .externalChangeDetected
    }
    return .newOrUnvisited
  }

  /// Folder mode only: the decision for re-recognizing a space already decided to be
  /// "unmanaged", by matching its wallpaper path.
  /// (A space marked unmanaged loses its beacon, so from then on it can only be re-recognized
  /// by the wallpaper path recorded at that time. If the user changes to yet another wallpaper,
  /// we can no longer re-recognize it and it falls back to being treated as a new space, but
  /// this is acceptable because it is consistent with the policy "marked unmanaged = we no
  /// longer interfere")
  static func isKnownUnmanagedPath(_ currentImagePath: String, unmanagedPaths: [String]) -> Bool {
    unmanagedPaths.contains(currentImagePath)
  }

  /// Folder mode only: a two-consecutive-match debounce that keeps the "window-based decision"
  /// (a window of the currently active space remains on this screen) from being finalized on a
  /// single observation.
  ///
  /// Background: NSWindow.isOnActiveSpace can momentarily return true for windows of the
  /// previous space during a space switch / Mission Control transition. Also, while a wallpaper
  /// transition is in progress, desktopImageURL may temporarily return the previous space's
  /// value or an intermediate one. If we finalized these transient observations as external
  /// changes, we would mistakenly trigger regenerateBeacon (the same media gets re-beaconed
  /// onto a different space) or markUnmanaged (deleting the correct space's beacon HEIC and
  /// turning the screen black).
  ///
  /// Therefore, we finalize (.confirmed) only after observing "the same window (identity)" and
  /// "the same non-beacon wallpaper path" twice in a row without an intervening space switch
  /// (activeSpaceDidChangeNotification etc.). The caller (FolderSpaceCoordinator.performRefresh)
  /// schedules its own re-check about 2 seconds after recording the first .pending observation
  /// (scheduleWindowSuspicionRecheck, a one-shot task of Task.sleep(nanoseconds:) + refresh()),
  /// so completing the "two consecutive observations" normally takes only about 2 seconds. The
  /// existing 60-second polling timer remains as a fallback net in case that dedicated
  /// scheduling somehow fails to fire (in the worst case a re-check happens within 60 seconds).
  /// Following the same "stateless pure function" convention as
  /// ExternalWallpaperChangeDetector.decide, the caller passes in the previous suspicion state,
  /// receives the new state, and writes it back to its own property
  enum WindowSuspicion {
    /// Represents a single observation. windowID uses the identifier (`ObjectIdentifier`) of
    /// WallpaperWindowControlling so that we do not depend on AppKit (for unit-test ease, for
    /// the same reason as BeaconRegenerationPolicy)
    struct Observation: Equatable {
      let windowID: ObjectIdentifier
      let imagePath: String
    }

    enum Decision: Equatable {
      /// Not finalized yet. The observation should be recorded as the "suspicion" for the next
      /// check (covers both the first observation and restarting as a fresh suspicion after a
      /// reset)
      case pending(Observation)
      /// The same window and the same wallpaper path were observed twice in a row within the
      /// same residency. It is safe to finalize this as an external change
      case confirmed
    }

    /// - Parameters:
    ///   - priorSuspicion: The suspicion recorded on the previous check (nil if none)
    ///   - newObservation: The current observation
    ///   - spaceChangeObservedSinceLastCheck: Whether a space switch
    ///     (activeSpaceDidChangeNotification etc.) occurred after the previous check completed.
    ///     When true, the premise of "a re-check within the same residency" is broken, so we
    ///     reset even if the observations match
    static func decide(
      priorSuspicion: Observation?,
      newObservation: Observation,
      spaceChangeObservedSinceLastCheck: Bool
    ) -> Decision {
      if !spaceChangeObservedSinceLastCheck, let priorSuspicion, priorSuspicion == newObservation {
        return .confirmed
      }
      return .pending(newObservation)
    }
  }

  /// Folder mode only: a two-consecutive-match debounce that keeps the observation "no windows
  /// remain on this screen at all" itself from being finalized on a single observation (a
  /// sister of WindowSuspicion).
  ///
  /// Background (issue D): when currentUUID is nil (the wallpaper is not in a known beacon
  /// form) and not a single isOnActiveSpace window remains on this screen, the
  /// isFreshArrival-based ExternalWallpaperChangeDetector.decide previously concluded
  /// .newOrUnvisited from that single observation as-is and immediately ran performAssignment
  /// (a fresh random assignment). However, NSWindow.isOnActiveSpace can momentarily return
  /// false right after a space switch (see the WindowSuspicion comment), so the "no windows"
  /// observation itself can be a transient error (= we actually just came back to a space that
  /// does have windows). Finalizing this from a single observation and immediately running
  /// performAssignment would silently overwrite a wallpaper the user just changed manually with
  /// different media.
  ///
  /// Therefore, following the same convention as WindowSuspicion, we finalize (.confirmed = it
  /// is OK to run performAssignment as a new/unvisited space) only after observing "the same
  /// non-beacon wallpaper path" and "no windows" twice in a row without an intervening space
  /// switch. Right after the first .pending observation, the caller schedules a re-check about
  /// 2 seconds later, the same as WindowSuspicion
  /// (FolderSpaceCoordinator.scheduleNoResidentWindowSuspicionRecheck).
  ///
  /// Scope note (the exact boundary of the known limitation): when currentUUID matches an
  /// existing binding's beacon (this includes spaces where image media is "correctly assigned";
  /// for image media, setBeacon itself is the finished wallpaper, so a correctly assigned image
  /// space structurally has no windows), processing completes at an earlier branch of
  /// performRefresh (the (a)/(b) branch for currentUUID != nil) and never reaches this decision
  /// in the first place. Therefore, when "a space assigned image media had its wallpaper
  /// manually changed while the user was away", the space has no windows and currentUUID is nil
  /// at the time the user returns, so (unless it also matches isKnownUnmanagedPath) it is still
  /// treated as a "new/unvisited space" even after this debounce. This is a deliberate, known
  /// limitation: what this debounce fixes is strictly the "transient window-observation error
  /// right after arriving at a new/unvisited space", not detection of manual changes on image
  /// spaces itself
  enum NoResidentWindowSuspicion {
    /// Represents a single observation. Since there is no window, it carries no windowID and is
    /// identified by the wallpaper path alone
    struct Observation: Equatable {
      let imagePath: String
    }

    enum Decision: Equatable {
      /// Not finalized yet. Should be recorded as the "suspicion" for the next check
      case pending(Observation)
      /// The same wallpaper path with no windows was observed twice in a row within the same
      /// residency. It is safe to finalize this as a new/unvisited space
      case confirmed
    }

    /// - Parameters:
    ///   - priorSuspicion: The suspicion recorded on the previous check (nil if none)
    ///   - newObservation: The current observation
    ///   - spaceChangeObservedSinceLastCheck: Whether a space switch occurred after the
    ///     previous check completed. When true, we reset even if the observations match (same
    ///     as WindowSuspicion.decide)
    static func decide(
      priorSuspicion: Observation?,
      newObservation: Observation,
      spaceChangeObservedSinceLastCheck: Bool
    ) -> Decision {
      if !spaceChangeObservedSinceLastCheck, let priorSuspicion, priorSuspicion == newObservation {
        return .confirmed
      }
      return .pending(newObservation)
    }
  }
}
