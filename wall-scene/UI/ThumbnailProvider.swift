import AVFoundation
import AppKit
import UniformTypeIdentifiers

/// Lightweight thumbnail infrastructure dedicated to previews in the settings UI.
/// - Handles first-frame extraction for videos (AVAssetImageGenerator), thumbnail generation for
///   GIFs/images (ImageIO), and lightweight enumeration of media directly under a folder.
/// - The enumeration here is exclusively for UI previews (item counts, stacked previews) and is
///   distinct from the authoritative scan that decides what gets played
///   (MediaLibrary.scanPlayableMedia, which includes AVURLAsset.isPlayable validation).
///   MediaLibrary is dedicated to the authoritative scan (with isPlayable validation), so we
///   duplicate a lightweight version here for UI previews.
@MainActor
final class ThumbnailProvider {
  static let shared = ThumbnailProvider()

  private let cache = NSCache<NSString, NSImage>()

  private init() {}

  /// Returns a thumbnail for a media file (video, GIF, or image). Returns nil instead of
  /// throwing when a thumbnail cannot be produced.
  /// Example: `let image = await ThumbnailProvider.shared.mediaThumbnail(path: path, maxPixel: 320)`
  func mediaThumbnail(path: String, maxPixel: CGFloat) async -> NSImage? {
    let cacheKey = "\(path)#\(Int(maxPixel))" as NSString
    if let cached = cache.object(forKey: cacheKey) {
      return cached
    }

    let url = URL(fileURLWithPath: path)
    let image: NSImage?
    switch MediaKind.classify(url: url) {
    case .video:
      image = await videoFrame(url: url, maxPixel: maxPixel)
    case .gif, .image:
      image = imageFrame(url: url, maxPixel: maxPixel)
    case .none:
      // When the extension/UTType cannot classify the file, try it as a video
      // (preserves the previous behavior)
      image = await videoFrame(url: url, maxPixel: maxPixel)
    }

    guard let image else { return nil }
    cache.setObject(image, forKey: cacheKey)
    return image
  }

  private func videoFrame(url: URL, maxPixel: CGFloat) async -> NSImage? {
    let asset = AVURLAsset(url: url)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero

    var cgImage = try? await copyCGImage(generator: generator, time: .zero)
    if cgImage == nil {
      // Some videos cannot yield a frame at exactly time zero, so fall back to a slightly
      // later timestamp
      cgImage = try? await copyCGImage(generator: generator, time: CMTime(value: 1, timescale: 10))
    }
    guard let cgImage else { return nil }
    return NSImage(cgImage: cgImage, size: .zero)
  }

  private func copyCGImage(generator: AVAssetImageGenerator, time: CMTime) async throws -> CGImage {
    let (image, _) = try await generator.image(at: time)
    return image
  }

  /// Thumbnail for GIFs/images. Uses ImageIO's thumbnail generation (including EXIF
  /// orientation correction).
  /// For GIFs this yields frame 0 (the first frame)
  private func imageFrame(url: URL, maxPixel: CGFloat) -> NSImage? {
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    ]
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    else {
      return nil
    }
    return NSImage(cgImage: cgImage, size: .zero)
  }

  /// Lightweight enumeration of media candidates (videos, GIFs, images) directly under a folder.
  /// Classifies by UTType only and skips isPlayable validation (to keep previews cheap; the
  /// authoritative scan for playback targets is MediaLibrary's job).
  /// Example: `let paths = await ThumbnailProvider.shared.folderMediaList(folderPath: folderPath)`
  func folderMediaList(folderPath: String) async -> [String] {
    let fm = FileManager.default
    let folderURL = URL(fileURLWithPath: folderPath)
    guard
      let entries = try? fm.contentsOfDirectory(
        at: folderURL,
        includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey, .contentTypeKey],
        options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
      )
    else {
      return []
    }

    let paths = entries.compactMap { url -> String? in
      guard
        let values = try? url.resourceValues(forKeys: [
          .isDirectoryKey, .isHiddenKey, .contentTypeKey,
        ])
      else {
        return nil
      }
      if values.isDirectory == true { return nil }
      if values.isHidden == true { return nil }
      guard let type = values.contentType, MediaKind.classify(contentType: type) != nil else {
        return nil
      }
      return url.path
    }

    return paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
  }
}
