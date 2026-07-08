import CoreGraphics

/// Shared utility that computes a frame that "fits" or "fills" the given bounds while
/// preserving aspect ratio. Used to reproduce the look of
/// AVLayerVideoGravity.resizeAspectFill (fill) / .resizeAspect (fit) on NSImageView
/// (animated GIFs and still images), which has no videoGravity of its own.
enum AspectGeometry {
  enum Mode {
    case fill
    case fit
  }

  /// Example: `let frame = AspectGeometry.frame(forContentSize: image.size, fitting: bounds, mode: .fill)`
  static func frame(forContentSize contentSize: CGSize, fitting bounds: CGRect, mode: Mode)
    -> CGRect
  {
    guard contentSize.width > 0, contentSize.height > 0, bounds.width > 0, bounds.height > 0 else {
      return bounds
    }
    let contentAspect = contentSize.width / contentSize.height
    let boundsAspect = bounds.width / bounds.height

    let scaledSize: CGSize
    switch mode {
    case .fill:
      if contentAspect > boundsAspect {
        scaledSize = CGSize(width: bounds.height * contentAspect, height: bounds.height)
      } else {
        scaledSize = CGSize(width: bounds.width, height: bounds.width / contentAspect)
      }
    case .fit:
      if contentAspect > boundsAspect {
        scaledSize = CGSize(width: bounds.width, height: bounds.width / contentAspect)
      } else {
        scaledSize = CGSize(width: bounds.height * contentAspect, height: bounds.height)
      }
    }

    let origin = CGPoint(
      x: bounds.midX - scaledSize.width / 2, y: bounds.midY - scaledSize.height / 2)
    return CGRect(origin: origin, size: scaledSize)
  }
}
