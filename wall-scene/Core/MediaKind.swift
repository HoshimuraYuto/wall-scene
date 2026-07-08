import Foundation
import UniformTypeIdentifiers

/// Media kind classification (a shared UTType-based helper).
/// Centralizes the video/GIF/image detection logic used by both single mode and folder mode.
///
/// The check order matters: GIFs must be "treated as video" (their animation is loop-played,
/// never shown as a still image), so we always check in the order gif → movie/video → image
/// (UTType.gif also conforms to UTType.image, so checking image first would cause GIFs to be
/// treated as still images).
enum MediaKind: Equatable {
  case video
  case gif
  case image

  /// Classifies from a UTType. Returns nil if it matches none of the kinds (unsupported file).
  /// Usage: `let kind = MediaKind.classify(contentType: .mpeg4Movie)`
  static func classify(contentType: UTType) -> MediaKind? {
    if contentType.conforms(to: .gif) {
      return .gif
    }
    if contentType.conforms(to: .movie) || contentType.conforms(to: .video) {
      return .video
    }
    if contentType.conforms(to: .image) {
      return .image
    }
    return nil
  }

  /// Classifies from a file URL's contentType (via resourceValues). Returns nil if it cannot
  /// be retrieved.
  /// Usage: `let kind = MediaKind.classify(url: fileURL)`
  static func classify(url: URL) -> MediaKind? {
    guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
      return nil
    }
    return classify(contentType: type)
  }
}
