import SwiftUI
import UIKit

/// A brief receipt for an already committed tool use, not a delayed action.
struct DirectToolRevealView: UIViewRepresentable {
    let reveal: GameRewardPresentation.ToolReveal
    let protectedCells: [CGRect]

    func makeUIView(context: Context) -> DirectToolRevealUIView { DirectToolRevealUIView() }
    func updateUIView(_ view: DirectToolRevealUIView, context: Context) {
        view.configure(reveal: reveal, protectedCells: protectedCells)
    }
    static func dismantleUIView(_ view: DirectToolRevealUIView, coordinator: ()) { view.cancel() }
}

/// Corners identify the accepted tile while its happy face remains unobstructed.
/// The same mask also protects existing and newly added board content in flight.
final class DirectToolRevealUIView: UIView {
    private let corners = CAShapeLayer()
    private let backdrop = CAShapeLayer()
    private let lens = CALayer()
    private let contentMask = CAShapeLayer()
    private var eventID: UUID?
    private var protectedCells: [CGRect] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false; accessibilityElementsHidden = true
        backgroundColor = .clear
        for stroke in [backdrop, corners] {
            stroke.fillColor = UIColor.clear.cgColor
            stroke.lineCap = .round; stroke.lineJoin = .round
            layer.addSublayer(stroke)
        }
        corners.name = "direct-target-corners"
        corners.strokeColor = UIColor(CapyPalette.actionOrange).cgColor
        backdrop.strokeColor = UIColor.white.withAlphaComponent(0.95).cgColor
        lens.name = "direct-tool-lens"
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 33, height: 33))
        lens.contents = renderer.image { _ in
            UIColor(CapyPalette.paper).withAlphaComponent(0.92).setFill()
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: 33, height: 33)).fill()
            UIImage(systemName: "magnifyingglass", withConfiguration: UIImage.SymbolConfiguration(pointSize: 23, weight: .bold))?
                .withTintColor(UIColor(CapyPalette.actionOrange), renderingMode: .alwaysOriginal)
                .draw(in: CGRect(x: 5, y: 5, width: 23, height: 23))
        }.cgImage
        lens.bounds = CGRect(x: 0, y: 0, width: 33, height: 33)
        layer.addSublayer(lens)
        contentMask.fillRule = .evenOdd
        layer.mask = contentMask
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(reveal: GameRewardPresentation.ToolReveal, protectedCells: [CGRect]) {
        self.protectedCells = (protectedCells + [reveal.cellFrame]).reduce(into: []) { result, cell in
            // Window conversion and grid reconstruction can differ by a few
            // floating-point bits. Duplicate even-odd holes would cancel out.
            if !result.contains(where: {
                abs($0.minX - cell.minX) < 0.001 && abs($0.minY - cell.minY) < 0.001 &&
                abs($0.width - cell.width) < 0.001 && abs($0.height - cell.height) < 0.001
            }) { result.append(cell) }
        }
        updateMask()
        guard eventID != reveal.id else { return }
        eventID = reveal.id
        let cell = reveal.cellFrame, side = min(cell.width, cell.height)
        let gap = max(1.1, min(2, side * 0.028))
        let frame = cell.insetBy(dx: gap * 0.4, dy: gap * 0.4)
        let length = side * 0.24
        let path = UIBezierPath()
        let points: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (frame.minX, frame.minY, 1, 1), (frame.maxX, frame.minY, -1, 1),
            (frame.minX, frame.maxY, 1, -1), (frame.maxX, frame.maxY, -1, -1)]
        for (x, y, dx, dy) in points {
            path.move(to: CGPoint(x: x + dx * length, y: y))
            path.addLine(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x, y: y + dy * length))
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for stroke in [backdrop, corners] {
            stroke.removeAllAnimations(); stroke.path = path.cgPath
            stroke.opacity = reveal.reduceMotion ? 0.9 : 0
        }
        corners.lineWidth = max(1.2, min(2.4, side * 0.055))
        backdrop.lineWidth = corners.lineWidth + 1
        lens.removeAllAnimations(); lens.opacity = 0
        lens.position = reveal.destination
        CATransaction.commit()
        guard !reveal.reduceMotion else { return }
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0.95, 1, 0]; fade.keyTimes = [0, 0.22, 1]; fade.duration = 0.48
        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0.2; draw.toValue = 1; draw.duration = 0.10
        for stroke in [backdrop, corners] { stroke.add(fade, forKey: "receipt"); stroke.add(draw, forKey: "trace") }
        let travel = CABasicAnimation(keyPath: "position")
        travel.fromValue = NSValue(cgPoint: reveal.origin); travel.toValue = NSValue(cgPoint: reveal.destination)
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1; scale.toValue = 0.65
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = -16 * Double.pi / 180; turn.toValue = 12 * Double.pi / 180
        let disappear = CABasicAnimation(keyPath: "opacity")
        disappear.fromValue = 1; disappear.toValue = 0
        let flight = CAAnimationGroup(); flight.animations = [travel, scale, turn, disappear]
        flight.duration = 0.48; flight.timingFunction = CAMediaTimingFunction(name: .easeOut)
        lens.add(flight, forKey: "flight")
    }

    override func layoutSubviews() { super.layoutSubviews(); updateMask() }

    func cancel() {
        for item in [backdrop, corners, lens] { item.removeAllAnimations() }
    }

    private func updateMask() {
        let path = UIBezierPath(rect: bounds)
        for cell in protectedCells {
            let gap = max(1.1, min(2, cell.width * 0.028))
            path.append(UIBezierPath(rect: cell.insetBy(dx: gap, dy: gap)))
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        contentMask.frame = bounds; contentMask.path = path.cgPath
        contentMask.contentsScale = window?.screen.scale ?? traitCollection.displayScale
        for stroke in [backdrop, corners] { stroke.contentsScale = contentMask.contentsScale }
        CATransaction.commit()
    }
}
