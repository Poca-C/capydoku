import UIKit

/// Each strip contains three genuinely redrawn poses, not transforms of the
/// same mascot. The last pose is also the static/restored result illustration.
enum ResultCharacterPerformance: String, CaseIterable {
    case joyfulRaise, starHug, gentleRetry

    var assetName: String {
        switch self {
        case .joyfulRaise: return "CapyJoyfulPoses0226"
        case .starHug: return "CapyStarHugPoses0226"
        case .gentleRetry: return "CapyRetryPoses0226"
        }
    }

    var fallbackName: String { self == .gentleRetry ? "CapySad" : "CapyMascot" }

    /// These timings align real arm/head pose changes with the body motion.
    var poseIndices: [Int] {
        self == .joyfulRaise ? [0, 1, 2, 1, 2, 2] : [0, 1, 2, 2]
    }

    var poseTimes: [NSNumber] {
        switch self {
        case .joyfulRaise: return [0, 0.17, 0.43, 0.53, 0.78, 1]
        case .starHug: return [0, 0.20, 0.66, 1]
        case .gentleRetry: return [0, 0.20, 0.72, 1]
        }
    }
}

enum ResultCharacterArtwork {
    private static let cache = ResultCharacterImageCache { UIImage(named: $0) }
    static func poses(for performance: ResultCharacterPerformance) -> [UIImage] {
        cache.poses(for: performance)
    }
}

/// Decode/crop once per performance. Every square cell keeps the generated
/// common canvas and baseline, avoiding per-pose rescaling or head-size jumps.
final class ResultCharacterImageCache {
    private let load: (String) -> UIImage?
    private var images: [ResultCharacterPerformance: [UIImage]] = [:]
    init(load: @escaping (String) -> UIImage?) { self.load = load }

    func poses(for performance: ResultCharacterPerformance) -> [UIImage] {
        if let cached = images[performance] { return cached }
        let sheet = load(performance.assetName)
        guard let sheet, sheet.imageOrientation == .up, let source = sheet.cgImage,
              source.width >= 3, source.height > 0, source.width == source.height * 3 else {
            let fallback = load(performance.fallbackName).map { [$0, $0, $0] } ?? []
            images[performance] = fallback
            return fallback
        }
        let side = source.height
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        let outputSide: CGFloat = min(512, CGFloat(side))
        let size = CGSize(width: outputSide, height: outputSide)
        let frames = (0..<3).compactMap { index -> UIImage? in
            guard let crop = source.cropping(to: CGRect(x: index * side, y: 0, width: side, height: side)) else { return nil }
            return UIGraphicsImageRenderer(size: size, format: format).image { _ in
                UIImage(cgImage: crop).draw(in: CGRect(origin: .zero, size: size))
            }
        }
        if frames.count == 3 {
            images[performance] = frames
            return frames
        }
        let fallback = load(performance.fallbackName).map { [$0, $0, $0] } ?? []
        images[performance] = fallback
        return fallback
    }
}
