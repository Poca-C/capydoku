import UIKit
import CapydokuCore

/// Explains a failed placement using only animals the player has already found.
/// The view is decorative: it neither reads a solution nor blocks another move.
final class BoardConflictFeedbackView: UIView {
    let candidate: Int
    let conflicts: [VisiblePuzzleConflict]
    let highlightedCells: Set<Int>
    let connections: [(CGPoint, CGPoint)]
    let duration: TimeInterval = 1.35
    private let reduceMotion: Bool
    private var cleanup: DispatchWorkItem?

    init(frame: CGRect, boardRect: CGRect, size: Int, regions: [Int], candidate: Int,
         conflicts: [VisiblePuzzleConflict], reduceMotion: Bool) {
        self.candidate = candidate
        self.conflicts = conflicts
        self.reduceMotion = reduceMotion
        let count = (1...16).contains(size) ? size * size : 0
        let side = boardRect.width / CGFloat(max(1, size))
        func cellRect(_ index: Int) -> CGRect {
            CGRect(x: boardRect.minX + CGFloat(index % size) * side,
                   y: boardRect.minY + CGFloat(index / size) * side, width: side, height: side)
        }
        let valid = count > 0 && (0..<count).contains(candidate)
        let usable = valid ? conflicts.filter { (0..<count).contains($0.otherCell) && $0.otherCell != candidate } : []
        var highlighted = Set<Int>()
        if valid {
            for conflict in usable {
                for kind in conflict.kinds {
                    switch kind {
                    case .row: highlighted.formUnion((0..<size).map { candidate / size * size + $0 })
                    case .column: highlighted.formUnion((0..<size).map { $0 * size + candidate % size })
                    case .region:
                        if regions.indices.contains(candidate) {
                            highlighted.formUnion((0..<min(count, regions.count)).filter { regions[$0] == regions[candidate] })
                        }
                    case .adjacent:
                        highlighted.formUnion((0..<count).filter {
                            abs($0 / size - candidate / size) <= 1 && abs($0 % size - candidate % size) <= 1
                        })
                    }
                }
            }
        }
        highlightedCells = highlighted
        connections = usable.map {
            let a = cellRect(candidate), b = cellRect($0.otherCell)
            return (CGPoint(x: a.midX, y: a.midY), CGPoint(x: b.midX, y: b.midY))
        }
        super.init(frame: frame)
        isUserInteractionEnabled = false; isAccessibilityElement = false; accessibilityElementsHidden = true
        backgroundColor = .clear
        let mask = CAShapeLayer(); mask.path = UIBezierPath(roundedRect: boardRect, cornerRadius: 4).cgPath
        layer.mask = mask
        let color = UIColor(CapyPalette.life)
        let area = UIBezierPath()
        for index in highlighted.sorted() {
            area.append(UIBezierPath(roundedRect: cellRect(index).insetBy(dx: 2, dy: 2), cornerRadius: max(2, side * 0.05)))
        }
        let tint = CAShapeLayer(); tint.name = "conflict-visible-units"; tint.path = area.cgPath
        tint.fillColor = color.withAlphaComponent(0.08).cgColor; tint.strokeColor = color.withAlphaComponent(0.75).cgColor
        tint.lineWidth = min(1.5, side * 0.06); layer.addSublayer(tint)
        let links = UIBezierPath()
        for (a, b) in connections { links.move(to: a); links.addLine(to: b) }
        for (name, stroke, width) in [("conflict-link-outline", UIColor.white.withAlphaComponent(0.85), CGFloat(4)),
                                     ("conflict-link", color, CGFloat(2))] {
            let line = CAShapeLayer(); line.name = name; line.path = links.cgPath
            line.fillColor = UIColor.clear.cgColor; line.strokeColor = stroke.cgColor
            line.lineWidth = min(width, side * 0.13); line.lineDashPattern = [3, 4]; line.lineCap = .round
            layer.addSublayer(line)
        }
        let endpoints = UIBezierPath()
        for index in Set(usable.map(\.otherCell)).union(valid && !usable.isEmpty ? [candidate] : []) {
            endpoints.append(UIBezierPath(roundedRect: cellRect(index).insetBy(dx: 3, dy: 3), cornerRadius: max(2, side * 0.08)))
        }
        let rings = CAShapeLayer(); rings.name = "conflict-participants"; rings.path = endpoints.cgPath
        rings.fillColor = UIColor.clear.cgColor; rings.strokeColor = color.cgColor; rings.lineWidth = min(2.4, side * 0.10)
        layer.addSublayer(rings)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func play() {
        cleanup?.cancel()
        if !reduceMotion {
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0.25, 1, 1, 0]; fade.keyTimes = [0, 0.08, 0.78, 1]
            fade.duration = duration; layer.opacity = 0; layer.add(fade, forKey: "conflict-explanation")
        }
        let work = DispatchWorkItem { [weak self] in self?.removeFromSuperview() }
        cleanup = work; DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    override func willMove(toSuperview newSuperview: UIView?) {
        if newSuperview == nil { cleanup?.cancel(); cleanup = nil; layer.removeAllAnimations() }
        super.willMove(toSuperview: newSuperview)
    }
}
