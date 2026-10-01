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
    private static let rigCache = ResultRigImageCache { UIImage(named: $0) }
    static func poses(for performance: ResultCharacterPerformance) -> [UIImage] {
        cache.poses(for: performance)
    }

    /// Call from the existing loading gate: decode all cutouts and build the
    /// three short joint tracks before the first result can be presented.
    @discardableResult static func prewarmRig() -> Bool {
        let ready = rigCache.prepare()
        ResultRigMotion.prewarm()
        return ready
    }

    static func rigImage(_ part: ResultRigPart) -> UIImage? { rigCache.image(part) }
}

/// The generated atlases have transparent fractional-cell margins (the limbs
/// sheet is 1774×887). Explicit verified rectangles avoid rounding assumptions.
final class ResultRigImageCache {
    private let load: (String) -> UIImage?
    private var prepared = false
    private var images: [ResultRigPart: UIImage] = [:]
    private(set) var digestChecks = 0
    private(set) var alphaScanCount = 0
    init(load: @escaping (String) -> UIImage?) { self.load = load }

    static let coreBounds = [CGRect(x:45,y:102,width:569,height:505), CGRect(x:657,y:135,width:571,height:410),
        CGRect(x:47,y:722,width:576,height:420), CGRect(x:705,y:693,width:470,height:450)]
    static let limbBounds = [CGRect(x:117,y:62,width:251,height:364), CGRect(x:594,y:90,width:195,height:315),
        CGRect(x:1003,y:187,width:213,height:214), CGRect(x:1394,y:145,width:289,height:265),
        CGRect(x:105,y:477,width:247,height:359), CGRect(x:567,y:499,width:207,height:309),
        CGRect(x:997,y:592,width:210,height:198), CGRect(x:1399,y:553,width:296,height:269)]
    static let refinedArmBounds = [CGRect(x:117,y:57,width:251,height:370), CGRect(x:594,y:86,width:196,height:320),
        CGRect(x:104,y:474,width:247,height:363), CGRect(x:566,y:496,width:208,height:314)]

    func image(_ part: ResultRigPart) -> UIImage? { _ = prepare(); return images[part] }

    @discardableResult func prepare() -> Bool {
        if prepared { return images.count == ResultRigPart.allCases.count }
        prepared = true
        let atlases: [(String, Int, Int, String, [CGRect], [ResultRigPart])] = [
            ("CapyRigCore0229",1254,1254,"b60a16842ffe4666eadcea26ae757c49e8f263c201634b961d8325c3988b1a5d",Self.coreBounds,[.torso,.happyHead,.sadHead,.star]),
            // The local edit also changed non-target pixels. Reuse the original
            // paw/foot cutouts verbatim, and adopt only the four refined arms.
            ("CapyRigLimbs0229",1774,887,"5354358b312919d57dd9aa0351a047d19a5bbb35e249e1082d7f64fae2252353",[2,3,6,7].map { Self.limbBounds[$0] },[.leftPaw,.leftFoot,.rightPaw,.rightFoot]),
            ("CapyRigLimbs0230",1774,887,"707fa071a7b10c7ce8b4bd51e8ccf14cd6662d4413869d03b17e3353a7d4f1c1",Self.refinedArmBounds,[.leftUpperArm,.leftForearm,.rightUpperArm,.rightForearm])]
        for (name,width,height,digest,bounds,parts) in atlases {
            guard let image = load(name), image.imageOrientation == .up, let source = image.cgImage,
                  source.width == width, source.height == height else { images.removeAll(); return false }
            digestChecks += 1
            // An unknown/replaced sheet must not reuse old joint cutouts. Fail
            // to the complete existing mascot instead of silently misrigging it.
            guard CapyAlphaPlane.digest(in: source) == digest else { images.removeAll(); return false }
            for (part,rect) in zip(parts,bounds) {
                let cropRect = rect.insetBy(dx:-2,dy:-2).intersection(CGRect(x:0,y:0,width:width,height:height))
                guard let crop = source.cropping(to: cropRect) else { images.removeAll(); return false }
                let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
                // Decode once now, not when a newly discovered part first animates.
                let size = CGSize(width:crop.width,height:crop.height)
                images[part] = UIGraphicsImageRenderer(size:size,format:format).image { _ in
                    UIImage(cgImage:crop).draw(in:CGRect(origin:.zero,size:size))
                }
            }
        }
        return images.count == ResultRigPart.allCases.count
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
