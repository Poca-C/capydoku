import UIKit

enum CapyIdleGazeDirection: Int, CaseIterable { case left, right }

enum CapyIdleGazeArtwork {
    private static let cache = CapyIdleGazeImageCache { UIImage(named: $0) }
    static func image(_ direction: CapyIdleGazeDirection) -> UIImage? { cache.image(direction) }
}

/// The idle strip supplements the four existing expressions. Cropping and
/// normalization happen once per direction; replacement art retains a safe scan.
final class CapyIdleGazeImageCache {
    private let load: (String) -> UIImage?
    private var loaded = false
    private var source: CGImage?
    private var fallback: UIImage?
    private var bounds: [CapyIdleGazeDirection: CGRect]?
    private var images: [CapyIdleGazeDirection: UIImage] = [:]
    private var resolved = Set<CapyIdleGazeDirection>()
    private(set) var alphaScanCount = 0

    init(load: @escaping (String) -> UIImage?) { self.load = load }

    func image(_ direction: CapyIdleGazeDirection) -> UIImage? {
        if resolved.contains(direction) { return images[direction] }
        resolved.insert(direction)
        if !loaded {
            loaded = true; fallback = load("CapyFace")
            if let sheet = load("CapyIdleGaze0228"), sheet.imageOrientation == .up,
               let bitmap = sheet.cgImage, bitmap.width == bitmap.height * 2 {
                source = bitmap; bounds = CapyIdleGazeSheetMetrics.bounds(in: bitmap)
            }
        }
        guard let source,
              let crop = source.cropping(to: CGRect(x: direction.rawValue * source.height, y: 0,
                                                   width: source.height, height: source.height)) else {
            images[direction] = fallback; return fallback
        }
        let verified = (bounds?[direction]).flatMap { rect -> CGRect? in
            let canvas = CGRect(x: 0, y: 0, width: crop.width, height: crop.height)
            return !rect.isEmpty && rect == rect.integral && canvas.contains(rect) ? rect : nil
        }
        if verified == nil { alphaScanCount += 1 }
        let image = CapyExpressionImageCache.normalized(crop, bounds: verified) ?? fallback
        images[direction] = image; return image
    }
}

enum CapyIdleGazeSheetMetrics {
    static func bounds(in bitmap: CGImage) -> [CapyIdleGazeDirection: CGRect]? {
        guard bitmap.width == 1774, bitmap.height == 887,
              CapyAlphaPlane.digest(in: bitmap) == "9c1eef3f939ec83e0698a2560a13c7c2b82e0936fc6e99e203f09df80a4e611a" else { return nil }
        // Runtime normalization removes the generated 26px placement offset.
        // These exact bounds include the same 1px antialias margin as the scan.
        return [.left: CGRect(x: 56, y: 170, width: 820, height: 593),
                .right: CGRect(x: 30, y: 170, width: 820, height: 593)]
    }
}

/// One short look with blink bookends; the final underlying board stays neutral.
/// No state, sound, repeating job or hit target belongs to this decoration.
final class CapyIdleGazeView: UIView {
    let cellIndex: Int
    let direction: CapyIdleGazeDirection
    let duration: TimeInterval
    private let face = CALayer()
    private let reduceMotion: Bool
    private var generation = UUID()
    private var cleanupTask: DispatchWorkItem?

    init(cellIndex: Int, direction: CapyIdleGazeDirection, frame: CGRect,
         tileColor: UIColor, reduceMotion: Bool) {
        self.cellIndex = cellIndex; self.direction = direction; self.reduceMotion = reduceMotion
        duration = reduceMotion ? 0.18 : 0.82
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false; accessibilityElementsHidden = true
        backgroundColor = tileColor; clipsToBounds = true
        layer.cornerRadius = max(3, bounds.width * 0.05)
        face.name = "capy-idle-gaze"
        face.frame = bounds.insetBy(dx: bounds.width * 0.07, dy: bounds.height * 0.07)
        face.contentsGravity = .resizeAspect
        face.contents = CapyExpressionArtwork.image(.neutral)?.cgImage
        layer.addSublayer(face)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func play() {
        cleanupTask?.cancel(); face.removeAllAnimations()
        let token = UUID(); generation = token
        if !reduceMotion, let neutral = CapyExpressionArtwork.image(.neutral)?.cgImage,
           let blink = CapyExpressionArtwork.image(.blink)?.cgImage,
           let gaze = CapyIdleGazeArtwork.image(direction)?.cgImage {
            let poses = CAKeyframeAnimation(keyPath: "contents")
            poses.values = [blink, gaze, blink, neutral]
            poses.keyTimes = [0, 0.10, 0.83, 1]
            poses.calculationMode = .discrete; poses.duration = duration
            face.add(poses, forKey: "idle-look-poses")
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            self.removeFromSuperview()
        }
        cleanupTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    override func willMove(toSuperview newSuperview: UIView?) {
        if newSuperview == nil {
            generation = UUID(); cleanupTask?.cancel(); cleanupTask = nil
            face.removeAllAnimations(); layer.removeAllAnimations()
        }
        super.willMove(toSuperview: newSuperview)
    }
}
