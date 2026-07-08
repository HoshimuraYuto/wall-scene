import CoreGraphics

/// Pure logic that decides, in folder mode's (b-1) branch (a binding already exists and the
/// interval has not yet been exceeded, so we intend to reuse the beacon), whether that existing
/// beacon can be used as-is or needs to be re-rendered.
///
/// Why this was extracted on its own: it has no AppKit dependencies such as NSScreen, so it can
/// be verified from a standalone Swift script simply by loading it together with
/// SpaceBinding/ScalingMode (ContractsV2.swift). Embedding it inside a private method of
/// FolderSpaceCoordinator would make that verification impossible, which is why only this
/// decision was pulled out.
enum BeaconRegenerationPolicy {
  /// - Parameters:
  ///   - binding: the binding currently held (includes the scaling/pixel size at the time the
  ///     beacon was generated)
  ///   - currentScaling: the scaling the coordinator is currently using (= the display's
  ///     current setting)
  ///   - currentPixelSize: the screen's current pixel size (screen.frame.size × backingScaleFactor)
  ///   - beaconFileExists: whether the beacon-*.heic corresponding to binding.beaconUUID actually
  ///     exists on disk (the caller passes in the result of checking with FileManager.fileExists;
  ///     this function itself stays a pure function that performs no file I/O). If the HEIC was
  ///     lost to a past (false-positive) deletion and only the binding remains, the screen would
  ///     stay black indefinitely, so we have the beacon re-rendered as self-healing the next time
  ///     that space is visited (follow-up to P0-2)
  /// - Returns: true if the beacon needs to be re-rendered with the same media
  ///   (a binding with no recorded scaling/pixel size is treated as a previous-generation beacon
  ///   and always returns true; likewise, if the beacon file does not exist, this always
  ///   returns true)
  static func needsRegeneration(
    binding: SpaceBinding, currentScaling: ScalingMode, currentPixelSize: CGSize,
    beaconFileExists: Bool
  ) -> Bool {
    if !beaconFileExists {
      return true
    }
    guard let bindingScaling = binding.scaling,
      let width = binding.renderedPixelWidth,
      let height = binding.renderedPixelHeight
    else {
      return true
    }
    if bindingScaling != currentScaling {
      return true
    }
    let targetWidth = Int(currentPixelSize.width.rounded())
    let targetHeight = Int(currentPixelSize.height.rounded())
    return width != targetWidth || height != targetHeight
  }
}
