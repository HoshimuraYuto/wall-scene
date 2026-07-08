import AVFoundation
import CoreGraphics
import UniformTypeIdentifiers

/// Beacon image (HEIC) generation for folder mode.
/// Unlike ImportPipeline (the old implementation for the single/import flow), v1 folder mode plays
/// the original video directly without re-encoding, so this only extracts the step of "converting
/// the single image to be set as the wallpaper beacon to HEIC and saving it". Videos, GIFs, and
/// still images each require a different way of pulling out the source data, so makeBeaconHEIC has
/// a separate entry point per media type (only the HEIC export part is shared).
///
/// The destination path and file name must match exactly the convention read by
/// BeaconManager.beaconFileURL(for:) ("beacon-<UUID>.heic" directly under `Paths.beaconsDir`).
/// This is used by duplicating logic equivalent to ImportPipeline.writeHEIC / extractFirstFrame.
///
/// targetPixelSize/mode: rather than relying only on the options (imageScaling/allowClipping/
/// fillColor) that BeaconManager.setBeacon passes, the beacon bakes fit/fill into a bitmap of
/// exactly the screen's pixel size at generation time (ScaledImageRenderer + AspectGeometry; the
/// same idea as SingleVideoController.renderPosterImage). This works around the wallpaper system
/// on macOS 14 and later sometimes ignoring the options and drawing with fill-like behavior (a
/// problem when the image media becomes the beacon itself, since its appearance would not be
/// guaranteed).
enum FrameExtractor {
  /// Extracts the first frame of videoURL, bakes fit/fill into targetPixelSize, and saves it as
  /// HEIC at the conventional path that BeaconManager recognizes.
  /// Usage: `let heicURL = try await FrameExtractor.makeBeaconHEIC(from: videoURL, beaconUUID: uuid, targetPixelSize: size, mode: .fill)`
  nonisolated static func makeBeaconHEIC(
    from videoURL: URL, beaconUUID: UUID, targetPixelSize: CGSize, mode: AspectGeometry.Mode
  ) async throws -> URL {
    let asset = AVURLAsset(url: videoURL)
    let cgImage = try await extractFirstFrame(from: asset)
    let scaled = try scale(cgImage, targetPixelSize: targetPixelSize, mode: mode)
    return try writeBeaconHEIC(cgImage: scaled, beaconUUID: beaconUUID)
  }

  /// Loads a still image or the first frame of a GIF via ImageIO, bakes fit/fill into
  /// targetPixelSize, and saves it as a HEIC beacon. For a GIF, reading frame 0 yields the first
  /// frame (with animation compositing already applied), so still images and GIFs both share this
  /// single implementation.
  /// Usage: `let heicURL = try await FrameExtractor.makeBeaconHEIC(fromImage: imageURL, beaconUUID: uuid, targetPixelSize: size, mode: .fit)`
  nonisolated static func makeBeaconHEIC(
    fromImage imageURL: URL, beaconUUID: UUID, targetPixelSize: CGSize, mode: AspectGeometry.Mode
  ) async throws -> URL {
    let cgImage = try loadFirstFrame(fromImage: imageURL)
    let scaled = try scale(cgImage, targetPixelSize: targetPixelSize, mode: mode)
    return try writeBeaconHEIC(cgImage: scaled, beaconUUID: beaconUUID)
  }

  private nonisolated static func scale(
    _ cgImage: CGImage, targetPixelSize: CGSize, mode: AspectGeometry.Mode
  )
    throws -> CGImage
  {
    guard let scaled = ScaledImageRenderer.render(cgImage, targetSize: targetPixelSize, mode: mode)
    else {
      throw WallSceneError.beaconWriteFailed(String(localized: "Failed to scale the beacon image"))
    }
    return scaled
  }

  private nonisolated static func writeBeaconHEIC(cgImage: CGImage, beaconUUID: UUID) throws -> URL
  {
    try FileManager.default.createDirectory(at: Paths.beaconsDir, withIntermediateDirectories: true)
    // The "beacon-" prefix and ".heic" suffix must match BeaconManager's private static let
    // prefix/suffix (the convention strings are duplicated verbatim here).
    let heicURL = Paths.beaconsDir.appendingPathComponent(
      "beacon-" + beaconUUID.uuidString + ".heic")
    try writeHEIC(cgImage: cgImage, to: heicURL)
    return heicURL
  }

  // MARK: - Loading the first frame of an image/GIF

  /// Fetches frame 0 with EXIF orientation applied (kCGImageSourceCreateThumbnailWithTransform).
  /// Falls back to the untransformed frame 0 if thumbnail generation fails.
  private nonisolated static func loadFirstFrame(fromImage imageURL: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil) else {
      throw WallSceneError.beaconWriteFailed(
        String(localized: "Failed to load the image: \(imageURL.lastPathComponent)"))
    }
    let thumbnailOptions: [CFString: Any] = [
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceThumbnailMaxPixelSize: 8192,
    ]
    if let thumbnail = CGImageSourceCreateThumbnailAtIndex(
      source, 0, thumbnailOptions as CFDictionary)
    {
      return thumbnail
    }
    guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      throw WallSceneError.beaconWriteFailed(
        String(localized: "Failed to load the image: \(imageURL.lastPathComponent)"))
    }
    return cgImage
  }

  // MARK: - First-frame extraction

  private nonisolated static func extractFirstFrame(from asset: AVURLAsset) async throws -> CGImage
  {
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero

    if let image = try? await copyCGImage(generator: generator, time: .zero) {
      return image
    }
    // Some videos cannot yield a frame at exactly the start, so fall back to a slightly later time
    if let image = try? await copyCGImage(
      generator: generator, time: CMTime(value: 1, timescale: 10))
    {
      return image
    }
    throw WallSceneError.beaconWriteFailed(String(localized: "Failed to extract the first frame"))
  }

  private nonisolated static func copyCGImage(generator: AVAssetImageGenerator, time: CMTime)
    async throws
    -> CGImage
  {
    if #available(macOS 13.0, *) {
      let (image, _) = try await generator.image(at: time)
      return image
    } else {
      return try generator.copyCGImage(at: time, actualTime: nil)
    }
  }

  // MARK: - HEIC export

  private nonisolated static func writeHEIC(cgImage: CGImage, to url: URL) throws {
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
    guard
      let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.heic.identifier as CFString,
        1,
        nil
      )
    else {
      throw WallSceneError.beaconWriteFailed(
        String(localized: "Failed to create the HEIC export destination"))
    }
    let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
    CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      throw WallSceneError.beaconWriteFailed(String(localized: "Failed to export the HEIC file"))
    }
  }
}
