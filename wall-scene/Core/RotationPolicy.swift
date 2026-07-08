import Foundation

/// Pure logic for folder mode's branch (b) (the check that runs on arrival at, or while polling,
/// a space that already has a binding): decides whether the existing assignment can be kept as-is
/// or a re-draw is required.
///
/// To route every RotationTiming case through a single unified path, the shared decision basis is
/// "is binding.assignedAt older than the most recent rotation reference time the coordinator has
/// recorded (lastRotationEpoch)?":
/// - `.onLogin`: the coordinator's start() sets lastRotationEpoch to the time the app process
///   launched (not "now" — a coordinator can be recreated mid-session, e.g. on a scaling/timing
///   change or a display reconnect, and only an actual app launch should count). Any binding
///   assigned in the previous process run is necessarily older than that, so it gets re-drawn
///   exactly once the next time that space is visited (in visit order, not all spaces at once).
/// - `.onWake`: updated the same way on every NSWorkspace.didWakeNotification (wake from sleep).
/// - `.interval(minutes:)`: not covered by the reference-time updates (lastRotationEpoch can stay
///   at its initial value .distantPast); instead, the decision is whether the elapsed minutes are
///   greater than or equal to the interval.
///
/// Why this was extracted as a standalone unit: like BeaconRegenerationPolicy, it has no AppKit
/// dependency, so it can be verified simply by loading it together with ContractsV2.swift from an
/// independent Swift script. Embedding it inside a private method of FolderSpaceCoordinator would
/// make it impossible to verify, so only this decision was pulled out.
enum RotationPolicy {
  /// - Parameters:
  ///   - binding: the currently held binding (assignedAt = time of the most recent
  ///     assignment/re-beacon)
  ///   - timing: this display's current rotation timing setting
  ///   - now: the time of the decision (normally Date())
  ///   - lastRotationEpoch: the most recent rotation reference time recorded by the coordinator
  ///     (updated when an onLogin/onWake event fires; .distantPast if nothing has happened)
  /// - Returns: true if a re-draw is required
  static func needsReassignment(
    binding: SpaceBinding,
    timing: RotationTiming,
    now: Date,
    lastRotationEpoch: Date
  ) -> Bool {
    if binding.assignedAt < lastRotationEpoch {
      return true
    }
    if case .interval(let minutes) = timing {
      let elapsedMinutes = now.timeIntervalSince(binding.assignedAt) / 60
      return elapsedMinutes >= Double(minutes)
    }
    return false
  }
}
