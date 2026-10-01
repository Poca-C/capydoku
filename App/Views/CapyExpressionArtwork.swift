import UIKit

/// Four equally sized cells in the original Demo sheet, read left to right.
/// Artwork changes expression only; it never supplies gameplay information.
enum CapyFaceExpression: Int, CaseIterable {
    case neutral, blink, happy, startled
}

enum CapyExpressionArtwork {
    private static let cache = CapyExpressionImageCache { UIImage(named: $0) }

    static func image(_ expression: CapyFaceExpression) -> UIImage? {
        cache.image(for: expression)
    }
}

/// The small cache decodes the sheet once and crops each expression once.
/// An injectable image lookup also covers missing or invalid asset bundles.
final class CapyExpressionImageCache {
    private let load: (String) -> UIImage?
    private var loaded = false
    private var sheet: UIImage?
    private var fallback: UIImage?
    private var images: [CapyFaceExpression: UIImage] = [:]
    private var resolved: Set<CapyFaceExpression> = []

    init(load: @escaping (String) -> UIImage?) { self.load = load }

    func image(for expression: CapyFaceExpression) -> UIImage? {
        if resolved.contains(expression) { return images[expression] }
        resolved.insert(expression)
        if !loaded {
            loaded = true
            fallback = load("CapyFace")
            sheet = load("CapyFaceExpressions")
            // Imported PNGs are upright. Normalize other orientations before
            // deciding quadrants so visual top-left always means neutral.
            if let source = sheet, source.imageOrientation != .up {
                let format = UIGraphicsImageRendererFormat()
                format.scale = source.scale; format.opaque = false
                sheet = UIGraphicsImageRenderer(size: source.size, format: format).image { _ in
                    source.draw(in: CGRect(origin: .zero, size: source.size))
                }
            }
        }
        guard let sheet, let source = sheet.cgImage,
              source.width >= 2, source.height >= 2,
              source.width.isMultiple(of: 2), source.height.isMultiple(of: 2) else {
            images[expression] = fallback
            return fallback
        }
        let width = source.width / 2, height = source.height / 2
        let crop = CGRect(x: (expression.rawValue % 2) * width,
                          y: (expression.rawValue / 2) * height,
                          width: width, height: height)
        guard let bitmap = source.cropping(to: crop) else {
            images[expression] = fallback
            return fallback
        }
        guard let result = Self.normalized(bitmap) else {
            images[expression] = fallback
            return fallback
        }
        images[expression] = result
        return result
    }

    private static func normalized(_ bitmap: CGImage) -> UIImage? {
        guard let content = alphaBounds(in: bitmap), let trimmed = bitmap.cropping(to: content) else { return nil }
        // Generated expressions can have different transparent margins. Place
        // visible artwork on one common anchor, preserving its aspect ratio.
        // A 512px canvas remains sharp for every supported board cell size.
        let side: CGFloat = 512, inset = side * 0.03
        let available = side - 2 * inset
        let scale = min(available / CGFloat(trimmed.width), available / CGFloat(trimmed.height))
        let size = CGSize(width: CGFloat(trimmed.width) * scale, height: CGFloat(trimmed.height) * scale)
        let destination = CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2,
                                 width: size.width, height: size.height)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            UIImage(cgImage: trimmed).draw(in: destination)
        }
    }

    private static func alphaBounds(in bitmap: CGImage) -> CGRect? {
        let width = bitmap.width, height = bitmap.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let didDraw = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(bitmap, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard didDraw else { return nil }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where bytes[(y * width + x) * 4 + 3] > 16 {
                minX = min(minX, x); minY = min(minY, y)
                maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // Keep one antialiasing pixel around the meaningful alpha contour.
        return CGRect(x: max(0, minX - 1), y: max(0, minY - 1),
                      width: min(width - 1, maxX + 1) - max(0, minX - 1) + 1,
                      height: min(height - 1, maxY + 1) - max(0, minY - 1) + 1)
    }
}
