import CoreGraphics

/// Shared helper that centralizes "composite the source image into a bitmap of exactly
/// targetSize (in pixels) using fit/fill" in one place.
///
/// Background: videos/GIFs are drawn by us inside the window via AVPlayerLayer.videoGravity /
/// AspectGeometry, so fit/fill reliably takes effect. Images, however, when implemented as
/// "keep the original aspect ratio and leave it to the options of
/// NSWorkspace.setDesktopImageURL (imageScaling/allowClipping/fillColor)", can be drawn as if
/// fill were requested because the wallpaper system on macOS 14 and later sometimes ignores the
/// options (a bug reported on real hardware).
/// By baking the image into a bitmap that exactly matches the screen size at generation time via
/// this function, the appearance is guaranteed regardless of how macOS interprets the options
/// (the options may remain as a harmless belt-and-suspenders measure).
///
/// Callers:
/// - Playback/WallpaperPosterCache.swift (wallpaper poster for single mode)
/// - Import/FrameExtractor.swift (beacon HEIC for folder mode)
/// - Playback/SingleVideoController.swift (in-window poster display during power-saving
///   fallback. Not a wallpaper replacement, but it needs the same fit/fill + black-bar
///   compositing, so the implementation is shared)
enum ScaledImageRenderer {
  /// - Parameters:
  ///   - image: source image
  ///   - targetSize: size of the output bitmap. For sharpness, callers must pass it in pixels
  ///     (screen.frame.size × screen.backingScaleFactor).
  ///   - mode: `.fit` = scale so the whole image fits, filling the leftover area with black
  ///     bars / `.fill` = scale up and crop (reuses the AspectGeometry.frame computation as is)
  /// - Returns: a CGImage of exactly targetSize, or nil if targetSize or the image size is
  ///   invalid
  nonisolated static func render(_ image: CGImage, targetSize: CGSize, mode: AspectGeometry.Mode)
    -> CGImage?
  {
    let width = Int(targetSize.width.rounded())
    let height = Int(targetSize.height.rounded())
    guard width > 0, height > 0, image.width > 0, image.height > 0 else { return nil }

    guard
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
      )
    else { return nil }

    // Letterbox area for fit (invisible in fill since the drawing covers it completely, but
    // always paint it just in case)
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    let contentSize = CGSize(width: image.width, height: image.height)
    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
    let drawRect = AspectGeometry.frame(forContentSize: contentSize, fitting: bounds, mode: mode)
    context.draw(image, in: drawRect)

    return context.makeImage()
  }
}
