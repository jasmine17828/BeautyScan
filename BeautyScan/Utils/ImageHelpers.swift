import UIKit
import ImageIO
import CoreGraphics

extension UIImage {
    /// Returns an upright CGImage with EXIF orientation applied, optionally downscaled for Vision.
    func normalizedCGForVision(maxDimension: CGFloat = 1600) -> CGImage? {
        let w = size.width, h = size.height
        guard w > 0, h > 0 else { return nil }
        let scale = min(1.0, maxDimension / max(w, h))
        let dstSize = CGSize(width: w * scale, height: h * scale)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = false
        let renderer = UIGraphicsImageRenderer(size: dstSize, format: fmt)
        let fixed = renderer.image { _ in
            self.draw(in: CGRect(origin: .zero, size: dstSize))
        }
        return fixed.cgImage
    }
}

extension CGImage {
    func toBGRA32PixelBuffer(maxDimension: CGFloat = 1600) -> CVPixelBuffer? {
        let srcW = CGFloat(self.width), srcH = CGFloat(self.height)
        guard srcW > 0, srcH > 0 else { return nil }
        let scale = min(1.0, maxDimension / max(srcW, srcH))
        let dstW = Int((srcW * scale).rounded()), dstH = Int((srcH * scale).rounded())

        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        var pb: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, dstW, dstH, kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let px = pb else { return nil }

        CVPixelBufferLockBaseAddress(px, [])
        defer { CVPixelBufferUnlockBaseAddress(px, []) }

        guard let base = CVPixelBufferGetBaseAddress(px) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(px)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: base, width: dstW, height: dstH,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                             | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }

        ctx.interpolationQuality = .high
        ctx.draw(self, in: CGRect(x: 0, y: 0, width: dstW, height: dstH))
        return px
    }
}
