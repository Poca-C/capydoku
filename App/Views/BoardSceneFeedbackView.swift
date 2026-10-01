import UIKit

/// Demo-only scene presentation. Its snapshot contains visible board state,
/// never an answer; the live board remains the owner of every input and result.
final class BoardSceneFeedbackView: UIView {
    enum Kind { case entrance, victory }
    let kind: Kind
    let duration: TimeInterval
    let simplified: Bool
    let tileFrames: [CGRect]
    private(set) var particleCount = 0
    private var cleanup: DispatchWorkItem?
    private var tileAnimations = [(CALayer, TimeInterval)]()
    private var faceAnimations = [(CALayer, TimeInterval)]()
    private var heartAnimations = [(CALayer, TimeInterval, CGFloat)]()
    private var stars = [CALayer]()
    private let glow = CAGradientLayer()

    init(kind: Kind, frame: CGRect, boardRect: CGRect, size: Int, regions: [Int], found: Set<Int>,
         finishingCells: Set<Int> = [], reduceMotion: Bool, lowPower: Bool) {
        self.kind = kind; simplified = reduceMotion || lowPower
        duration = simplified ? 0.18 : kind == .entrance ? 0.56 : 0.78
        let count = (1...16).contains(size) ? size * size : 0
        let side = boardRect.width / CGFloat(max(1, size))
        let gap = max(1.1, min(2, side * 0.028))
        let frames = (0..<count).map { index in
            CGRect(x: boardRect.minX + CGFloat(index % size) * side,
                   y: boardRect.minY + CGFloat(index / size) * side, width: side, height: side).insetBy(dx: gap, dy: gap)
        }
        tileFrames = frames
        super.init(frame: frame)
        isUserInteractionEnabled = false; isAccessibilityElement = false; accessibilityElementsHidden = true
        backgroundColor = .clear
        let mask = CAShapeLayer(); mask.path = UIBezierPath(roundedRect: boardRect, cornerRadius: 4).cgPath
        layer.mask = mask
        guard count > 0, regions.count == count else { return }
        if simplified {
            let border = CAShapeLayer(); border.name = "scene-static-outline"
            border.path = UIBezierPath(roundedRect: boardRect.insetBy(dx: 2, dy: 2), cornerRadius: 7).cgPath
            border.fillColor = UIColor.clear.cgColor; border.strokeColor = UIColor(CapyPalette.orange).cgColor
            border.lineWidth = 2; layer.addSublayer(border)
            return
        }
        if kind == .entrance {
            // Hide the already-drawn tiles while their decorative copies arrive.
            // The board cancels this cover on the first contact, before judgment.
            let paper = CALayer(); paper.name = "entrance-paper"; paper.frame = boardRect
            paper.backgroundColor = UIColor.white.cgColor; layer.addSublayer(paper)
            for index in 0..<count {
                let tile = makeTile(index: index, frame: frames[index], regions: regions)
                if found.contains(index) { _ = addFace(to: tile, expression: .neutral) }
                layer.addSublayer(tile)
                let diagonal = CGFloat(index / size + index % size) / CGFloat(max(1, (size - 1) * 2))
                tileAnimations.append((tile, TimeInterval(diagonal) * 0.24))
            }
        } else {
            glow.name = "victory-board-warmth"; glow.frame = boardRect
            glow.type = .radial; glow.startPoint = CGPoint(x: 0.5, y: 0.5); glow.endPoint = CGPoint(x: 1, y: 1)
            glow.colors = [UIColor(CapyPalette.orange).withAlphaComponent(0.34).cgColor,
                           UIColor(CapyPalette.orangeLight).withAlphaComponent(0.12).cgColor, UIColor.clear.cgColor]
            glow.locations = [0, 0.55, 1]; glow.opacity = 0; layer.addSublayer(glow)
            // A valid board has at most one found animal per row. Also cap
            // malformed drawing snapshots so decorative work remains bounded.
            let animals = found.filter { (0..<count).contains($0) }.sorted().prefix(size)
            for (rank, index) in animals.enumerated() {
                let tile = makeTile(index: index, frame: frames[index], regions: regions)
                let face = addFace(to: tile, expression: .happy)
                tile.name = "victory-animal-\(index)"; tile.opacity = 0; layer.addSublayer(tile)
                tileAnimations.append((tile, 0))
                // The newly found animal's existing 0.32s pop remains above this
                // overlay; its second little cheer starts after that pop ends.
                let delay = finishingCells.contains(index) ? 0.33 : min(0.20, Double(rank) * 0.024)
                faceAnimations.append((face, delay))
                addHeart(index: index, tile: frames[index], delay: delay)
                let radius = max(1.5, min(3.2, side * 0.07))
                let star = CAShapeLayer(); star.name = "victory-star-\(index)"
                star.frame = CGRect(x: frames[index].minX + frames[index].width * 0.17 - radius,
                                    y: frames[index].minY + frames[index].height * 0.15 - radius,
                                    width: radius * 2, height: radius * 2)
                let path = UIBezierPath()
                for step in 0..<8 {
                    let angle = CGFloat(step) * .pi / 4 - .pi / 2
                    let distance = step.isMultiple(of: 2) ? radius : radius * 0.34
                    let point = CGPoint(x: radius + cos(angle) * distance, y: radius + sin(angle) * distance)
                    if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                path.close(); star.path = path.cgPath
                star.fillColor = UIColor(CapyPalette.orange).cgColor; star.strokeColor = UIColor.white.cgColor
                star.lineWidth = 0.75; star.opacity = 0; layer.addSublayer(star); stars.append(star)
            }
            particleCount = stars.count + heartAnimations.count
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func makeTile(index: Int, frame: CGRect, regions: [Int]) -> CALayer {
        let tile = CALayer(); tile.name = "entrance-tile-\(index)"; tile.frame = frame
        let palette = ((regions[index] % CapyPalette.regionColors.count) + CapyPalette.regionColors.count) % CapyPalette.regionColors.count
        tile.backgroundColor = UIColor(CapyPalette.regionColors[palette]).cgColor
        tile.cornerRadius = max(3, frame.width * 0.05)
        return tile
    }

    private func addFace(to tile: CALayer, expression: CapyFaceExpression) -> CALayer {
        let face = CALayer(); face.name = "scene-face-\(expression)"
        face.frame = tile.bounds.insetBy(dx: tile.bounds.width * 0.07, dy: tile.bounds.height * 0.07)
        face.contents = CapyExpressionArtwork.image(expression)?.cgImage; face.contentsGravity = .resizeAspect
        tile.addSublayer(face); return face
    }

    private func addHeart(index: Int, tile: CGRect, delay: TimeInterval) {
        // R0229-03, original vectors in Capydoku's palette. These size/timing
        // values are Demo tuning; the heart occupies the space above the eyes.
        let side = min(10, max(3, tile.width * 0.17))
        let stroke: CGFloat = 0.7
        let radius = side * 0.53 + stroke / 2 + 0.1 // Includes the 1.06 peak scale.
        let lift = min(1.8, tile.height * 0.055)
        let heart = CAShapeLayer(); heart.name = "victory-heart-\(index)"
        heart.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        heart.position = CGPoint(x: min(tile.maxX - radius, max(tile.minX + radius, tile.minX + tile.width * 0.79)),
                                 y: max(tile.minY + radius + lift, tile.minY + tile.height * 0.18))
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 0.5, y: 0.91))
        path.addCurve(to: CGPoint(x: 0.07, y: 0.37), controlPoint1: CGPoint(x: 0.33, y: 0.76), controlPoint2: CGPoint(x: 0.07, y: 0.56))
        path.addCurve(to: CGPoint(x: 0.5, y: 0.25), controlPoint1: CGPoint(x: 0.07, y: 0.10), controlPoint2: CGPoint(x: 0.37, y: 0.08))
        path.addCurve(to: CGPoint(x: 0.93, y: 0.37), controlPoint1: CGPoint(x: 0.63, y: 0.08), controlPoint2: CGPoint(x: 0.93, y: 0.10))
        path.addCurve(to: CGPoint(x: 0.5, y: 0.91), controlPoint1: CGPoint(x: 0.93, y: 0.56), controlPoint2: CGPoint(x: 0.67, y: 0.76))
        path.close(); path.apply(CGAffineTransform(scaleX: side, y: side))
        heart.path = path.cgPath
        heart.fillColor = UIColor(CapyPalette.regionColors[9]).cgColor
        heart.strokeColor = UIColor(CapyPalette.paper).cgColor; heart.lineWidth = stroke
        heart.opacity = 0; layer.addSublayer(heart)
        heartAnimations.append((heart, delay, lift))
    }

    func play() {
        cleanup?.cancel()
        if !simplified {
            let now = CACurrentMediaTime()
            if kind == .entrance {
                for (tile, delay) in tileAnimations {
                    add(tile, key: "transform.scale", values: [0.84, 1.025, 1], times: [0, 0.72, 1],
                        duration: 0.24, beginTime: now + delay)
                    add(tile, key: "opacity", values: [0, 1], times: [0, 1], duration: 0.16, beginTime: now + delay)
                }
            } else {
                add(glow, key: "opacity", values: [0, 1, 0.65, 0], times: [0, 0.18, 0.58, 1], duration: 0.74, beginTime: now)
                for (tile, _) in tileAnimations {
                    add(tile, key: "opacity", values: [0, 1, 1, 0], times: [0, 0.08, 0.86, 1], duration: 0.74, beginTime: now)
                }
                for (face, delay) in faceAnimations {
                    add(face, key: "transform.scale", values: [1, 1.07, 0.98, 1], times: [0, 0.36, 0.75, 1], duration: 0.36, beginTime: now + delay)
                    let lift = min(3.2, face.bounds.height * 0.045)
                    add(face, key: "transform.translation.y", values: [0, -lift, 0], times: [0, 0.4, 1], duration: 0.36, beginTime: now + delay)
                }
                for (rank, star) in stars.enumerated() {
                    let delay = min(0.20, Double(rank) * 0.024)
                    add(star, key: "opacity", values: [0, 1, 0], times: [0, 0.25, 1], duration: 0.48, beginTime: now + delay)
                    add(star, key: "transform.scale", values: [0.4, 1, 0.7], times: [0, 0.35, 1], duration: 0.48, beginTime: now + delay)
                }
                for (heart, delay, lift) in heartAnimations {
                    // The final-cell heart starts after its existing 0.32s pop.
                    // All hearts finish by 0.75s, inside the unchanged 0.78s scene.
                    add(heart, key: "opacity", values: [0, 1, 1, 0], times: [0, 0.14, 0.70, 1], duration: 0.42, beginTime: now + delay)
                    add(heart, key: "transform.scale", values: [0.72, 1.06, 1, 0.9], times: [0, 0.30, 0.70, 1], duration: 0.42, beginTime: now + delay)
                    add(heart, key: "transform.translation.y", values: [0, -lift], times: [0, 1], duration: 0.42, beginTime: now + delay)
                }
            }
        }
        let work = DispatchWorkItem { [weak self] in self?.removeFromSuperview() }
        cleanup = work; DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func add(_ target: CALayer, key: String, values: [CGFloat], times: [NSNumber], duration: TimeInterval, beginTime: TimeInterval) {
        let animation = CAKeyframeAnimation(keyPath: key); animation.values = values; animation.keyTimes = times
        animation.duration = duration; animation.beginTime = beginTime; animation.fillMode = .backwards
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        target.add(animation, forKey: "scene-\(key)")
    }

    override func willMove(toSuperview newSuperview: UIView?) {
        if newSuperview == nil { cleanup?.cancel(); cleanup = nil; removeAnimations(layer) }
        super.willMove(toSuperview: newSuperview)
    }

    private func removeAnimations(_ root: CALayer) {
        root.removeAllAnimations(); root.sublayers?.forEach(removeAnimations)
    }
}
