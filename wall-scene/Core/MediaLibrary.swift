import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Media library scan for folder mode. Targets only the top level of the given folder and picks
/// out media that can be played/displayed (videos, GIFs, images) via classification by MediaKind
/// (UTType-based) plus a per-kind readability check.
/// - Videos: UTType pre-filter + final decision via AVURLAsset.isPlayable (same as before)
/// - GIFs/images: UTType pre-filter + a lightweight "can ImageIO (CGImageSource) read it" check
/// Usage: `let items = await MediaLibrary().scanPlayableMedia(in: folderURL)`
final class MediaLibrary: MediaLibraryScanning {
  nonisolated func scanPlayableMedia(in folderURL: URL) async -> [MediaItem] {
    let candidates = Self.candidateEntries(in: folderURL)

    var playable: [MediaItem] = []
    for (url, kind) in candidates {
      switch kind {
      case .video:
        let asset = AVURLAsset(url: url)
        do {
          let isPlayable = try await asset.load(.isPlayable)
          if isPlayable {
            playable.append(MediaItem(url: url, kind: .video))
          } else {
            Log.warn(
              "mediaLibrary", "Skipping because it was judged unplayable: \(url.lastPathComponent)")
          }
        } catch {
          Log.warn(
            "mediaLibrary",
            "Skipping because the playability check failed: \(url.lastPathComponent) (\(error.localizedDescription))"
          )
        }
      case .gif, .image:
        if Self.isReadableImage(url) {
          playable.append(MediaItem(url: url, kind: kind))
        } else {
          Log.warn(
            "mediaLibrary", "Skipping because it was judged unreadable: \(url.lastPathComponent)")
        }
      }
    }

    return playable.sorted {
      $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent)
        == .orderedAscending
    }
  }

  // MARK: - Top-level scan

  private nonisolated static func candidateEntries(in folderURL: URL) -> [(URL, MediaKind)] {
    let fm = FileManager.default
    guard
      let entries = try? fm.contentsOfDirectory(
        at: folderURL,
        includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey, .contentTypeKey],
        options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
      )
    else {
      Log.warn("mediaLibrary", "Failed to scan the folder: \(folderURL.path)")
      return []
    }

    return entries.compactMap { url -> (URL, MediaKind)? in
      guard
        let resourceValues = try? url.resourceValues(forKeys: [
          .isDirectoryKey, .isHiddenKey, .contentTypeKey,
        ])
      else {
        return nil
      }
      if resourceValues.isDirectory == true { return nil }
      if resourceValues.isHidden == true { return nil }
      guard let type = resourceValues.contentType, let kind = MediaKind.classify(contentType: type)
      else {
        return nil
      }
      return (url, kind)
    }
  }

  // MARK: - GIF/image readability check

  private nonisolated static func isReadableImage(_ url: URL) -> Bool {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
    return CGImageSourceGetCount(source) > 0
  }
}
