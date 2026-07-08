import AVFoundation
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Self-contained helper responsible solely for generating, caching, and cleaning up the poster
/// images used by single mode's "replace the wallpaper with a still image of the media" feature
/// (a workaround for Mission Control).
/// It has no AppKit dependencies such as NSWorkspace, and the caller (SingleVideoController)
/// passes in the directory, so it is easy to verify in isolation. It can also serve as the
/// foundation if the same kind of mechanism is later shared with a YouTube mode or similar.
///
/// File naming rule (important):
/// The name is derived deterministically from a hash of the media's absolute path (the key that
/// groups posters of the same media) + the scaling mode + the output pixel size + the
/// modification time (epoch seconds). The same media, same scaling, same pixel size, and same
/// mtime always produce the same file name, so if the file already exists it is reused as a
/// cache without regeneration (this also plays well with SingleVideoController skipping
/// re-application via its desktopImageURL comparison). Conversely, a changed mtime (= the content
/// has likely changed), a changed scaling setting, or a changed screen configuration
/// (resolution / Retina scale factor) each change the file name, which avoids both false hits in
/// the desktopImageURL comparison caused by overwriting a same-named file and stale entries in
/// macOS's own wallpaper cache. After a successful generation, only files with an older mtime for
/// the same media, same scaling, and same pixel size (= the same key) are cleaned up.
/// The cleanup scope is narrowed down to scaling/pixel size because, when the same media is used
/// in single mode across displays with different scaling/resolutions (e.g. setting the same video
/// separately on both a Retina built-in display and a non-Retina external display), one poster
/// generation could otherwise mistakenly clean up the other poster (= they would delete each
/// other and be regenerated every time). Posters for other displays, other media, or other
/// scaling/sizes are never deleted by mistake (although they do remain on disk).
enum WallpaperPosterCache {
  static let filePrefix = "single-poster-"
  private static let fileExtension = "jpg"
  private static let jpegQuality: CGFloat = 0.92

  /// Prepares the poster image for mediaURL inside directory and returns its URL.
  /// Rather than relying on the options, the generated image bakes the scaling (fit = letterbox /
  /// fill = crop) into a bitmap of exactly targetPixelSize (using ScaledImageRenderer +
  /// AspectGeometry; the same approach as the in-window rendering in
  /// SingleVideoController.renderPosterImage). The wallpaper system on macOS 14 and later
  /// sometimes ignores the options passed to setDesktopImageURL and draws as if fill were
  /// specified, so always keeping the image file itself at the same aspect ratio as the screen
  /// guarantees the appearance.
  /// If already cached (a file with the same name exists), it is returned as is (no regeneration).
  /// After generation, old poster files for the same media are cleaned up from directory.
  /// Returns nil if the mtime cannot be obtained, generation fails, or writing fails
  /// (the caller is expected to Log.warn, skip, and retry at the next opportunity).
  nonisolated static func ensurePoster(
    for mediaURL: URL,
    kind: MediaKind,
    scaling: ScalingMode,
    targetPixelSize: CGSize,
    directory: URL
  ) async -> URL? {
    guard let mtime = modificationDate(of: mediaURL) else { return nil }
    let target = posterURL(
      for: mediaURL, kind: kind, scaling: scaling, targetPixelSize: targetPixelSize, mtime: mtime,
      directory: directory)

    if FileManager.default.fileExists(atPath: target.path) {
      return target
    }

    guard let rawImage = await renderRawFrame(mediaURL: mediaURL, kind: kind) else { return nil }
    let mode: AspectGeometry.Mode = scaling == .fill ? .fill : .fit
    guard
      let cgImage = ScaledImageRenderer.render(rawImage, targetSize: targetPixelSize, mode: mode)
    else { return nil }

    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try writeJPEG(cgImage: cgImage, to: target)
    } catch {
      return nil
    }

    cleanupStalePosters(
      scopedPrefix: cacheKeyPrefix(
        pathHash: pathHash(for: mediaURL), scaling: scaling, targetPixelSize: targetPixelSize),
      keeping: target,
      directory: directory
    )
    return target
  }

  // MARK: - File name derivation (cache key)

  nonisolated static func posterURL(
    for mediaURL: URL, kind: MediaKind, scaling: ScalingMode, targetPixelSize: CGSize, mtime: Date,
    directory: URL
  ) -> URL {
    directory.appendingPathComponent(
      fileName(
        for: mediaURL, kind: kind, scaling: scaling, targetPixelSize: targetPixelSize, mtime: mtime)
    )
  }

  /// kind is not included in the file name (for the same path and same mtime, the kind detection
  /// result is also uniquely determined). It is kept as a parameter only to stay symmetric with
  /// the caller's signature (ensurePoster).
  nonisolated static func fileName(
    for mediaURL: URL, kind: MediaKind, scaling: ScalingMode, targetPixelSize: CGSize, mtime: Date
  ) -> String {
    let epoch = Int(mtime.timeIntervalSince1970)
    return
      "\(cacheKeyPrefix(pathHash: pathHash(for: mediaURL), scaling: scaling, targetPixelSize: targetPixelSize))\(epoch).\(fileExtension)"
  }

  /// File name prefix up to, but excluding, the mtime (epoch seconds). The common part of the
  /// "cache key" used both when assembling fileName and when narrowing the scope in
  /// cleanupStalePosters
  private nonisolated static func cacheKeyPrefix(
    pathHash: String, scaling: ScalingMode, targetPixelSize: CGSize
  ) -> String {
    let width = Int(targetPixelSize.width.rounded())
    let height = Int(targetPixelSize.height.rounded())
    return "\(filePrefix)\(pathHash)-\(scaling.rawValue)-\(width)x\(height)-"
  }

  /// Short hash derived from the media's absolute path. Used as the key that groups old and new
  /// poster files as belonging to the same media and narrows down the cleanup targets (file
  /// uniqueness is provided by the trailing mtime epoch seconds).
  nonisolated static func pathHash(for mediaURL: URL) -> String {
    let digest = SHA256.hash(data: Data(mediaURL.standardizedFileURL.path.utf8))
    return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
  }

  private nonisolated static func modificationDate(of url: URL) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
  }

  // MARK: - Generation (per kind)

  /// video uses the first frame (AVAssetImageGenerator); gif/image use frame 0 from
  /// CGImageSource. Even images go through this same unified path (instead of using the file
  /// as is) so that the caching/cleanup logic is shared across kinds (the same technique as
  /// FrameExtractor.loadFirstFrame(fromImage:)).
  /// Scaling is not baked in here yet (the original aspect ratio is kept); baking is done by the
  /// caller (ensurePoster) via ScaledImageRenderer.
  private nonisolated static func renderRawFrame(mediaURL: URL, kind: MediaKind) async -> CGImage? {
    switch kind {
    case .video:
      return await renderVideoFirstFrame(mediaURL: mediaURL)
    case .gif, .image:
      return renderImageFirstFrame(mediaURL: mediaURL)
    }
  }

  /// Same approach as FrameExtractor.extractFirstFrame (appliesPreferredTrackTransform, plus a
  /// slight time-offset fallback when a frame at exactly the start cannot be captured)
  private nonisolated static func renderVideoFirstFrame(mediaURL: URL) async -> CGImage? {
    let asset = AVURLAsset(url: mediaURL)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero

    if let image = try? await copyCGImage(generator: generator, time: .zero) {
      return image
    }
    return try? await copyCGImage(generator: generator, time: CMTime(value: 1, timescale: 10))
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

  /// Fetches frame 0 with EXIF orientation applied (for GIFs, frame 0 is obtained as the
  /// animation-composited first frame). Same implementation as
  /// FrameExtractor.loadFirstFrame(fromImage:)
  private nonisolated static func renderImageFirstFrame(mediaURL: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(mediaURL as CFURL, nil) else { return nil }
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
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
  }

  // MARK: - Writing and cleanup

  private nonisolated static func writeJPEG(cgImage: CGImage, to url: URL) throws {
    guard
      let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
    else {
      throw CocoaError(.fileWriteUnknown)
    }
    let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: jpegQuality]
    CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      throw CocoaError(.fileWriteUnknown)
    }
  }

  /// Deletes old poster files in directory that share the same cache key (same pathHash, scaling,
  /// and pixel size; only the mtime differs), preserving keeping. Posters for other displays with
  /// a different scaling/pixel size are out of scope (to prevent accidental deletion; see the
  /// comment on cacheKeyPrefix)
  private nonisolated static func cleanupStalePosters(
    scopedPrefix: String, keeping: URL, directory: URL
  ) {
    guard
      let entries = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
    else { return }
    for entry in entries {
      let name = entry.lastPathComponent
      guard name.hasPrefix(scopedPrefix),
        entry.standardizedFileURL.path != keeping.standardizedFileURL.path
      else { continue }
      try? FileManager.default.removeItem(at: entry)
    }
  }
}
