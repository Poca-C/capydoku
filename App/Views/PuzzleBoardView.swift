import SwiftUI
import UIKit
import CapydokuCore

struct PuzzleBoardView: UIViewRepresentable {
    let puzzle: Puzzle
    let found: Set<Int>
    let marks: Set<Int>
    let errors: Set<Int>
    var preview: Set<Int> = []
    var tutorialTargets: Set<Int> = []
    let locked: Bool
    let onToggle: (Int) -> Void
    let onSubmit: (Int) -> Void
    let onMark: ([Int]) -> Void

    func makeUIView(context: Context) -> PuzzleGridUIView {
        let view = PuzzleGridUIView()
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ uiView: PuzzleGridUIView, context: Context) {
        uiView.configure(size: puzzle.size, regions: puzzle.regions, found: found,
                         marks: marks, errors: errors, preview: preview,
                         tutorialTargets: tutorialTargets, locked: locked,
                         onToggle: onToggle, onSubmit: onSubmit, onMark: onMark)
    }
}

/// UIKit owns all three recognizers, so a double tap can never leak a single-tap X.
final class PuzzleGridUIView: UIView, UIGestureRecognizerDelegate {
    private var size = 4
    private var regions: [Int] = []
    private var found = Set<Int>()
    private var marks = Set<Int>()
    private var errors = Set<Int>()
    private var preview = Set<Int>()
    private var tutorialTargets = Set<Int>()
    private var locked = false
    private var onToggle: ((Int) -> Void)?
    private var onSubmit: ((Int) -> Void)?
    private var onMark: (([Int]) -> Void)?
    private var cells: [PuzzleCellAccessibilityElement] = []
    private enum DragAxis { case pending, horizontal, vertical, invalid }
    private var dragAxis: DragAxis = .pending
    private var dragStart: Int?
    private var visited = Set<Int>()
    private var dragStartPoint = CGPoint.zero
    private let ink = UIColor(CapyPalette.ink)
    private var hasConfigured = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isMultipleTouchEnabled = false
        isAccessibilityElement = false
        accessibilityIdentifier = "puzzle_board"
        let single = UITapGestureRecognizer(target: self, action: #selector(singleTap(_:)))
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
        double.numberOfTapsRequired = 2
        single.require(toFail: double)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        addGestureRecognizer(single)
        addGestureRecognizer(double)
        addGestureRecognizer(pan)
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(size: Int, regions: [Int], found: Set<Int>, marks: Set<Int>, errors: Set<Int>,
                   preview: Set<Int>, tutorialTargets: Set<Int>, locked: Bool,
                   onToggle: @escaping (Int) -> Void, onSubmit: @escaping (Int) -> Void,
                   onMark: @escaping ([Int]) -> Void) {
        let sameBoard = self.size == size && self.regions == regions
        let addedFound = found.subtracting(self.found)
        let addedErrors = errors.subtracting(self.errors)
        let changedMarks = marks.symmetricDifference(self.marks).subtracting(found).subtracting(errors)
        if !sameBoard {
            dragStart = nil
            visited.removeAll()
        }
        self.size = max(1, size)
        self.regions = regions
        self.found = found
        self.marks = marks
        self.errors = errors
        self.preview = preview
        self.tutorialTargets = tutorialTargets
        self.locked = locked
        self.onToggle = onToggle
        self.onSubmit = onSubmit
        self.onMark = onMark
        refreshAccessibility()
        setNeedsDisplay()
        if hasConfigured, sameBoard, window != nil, !UIAccessibility.isReduceMotionEnabled {
            for index in addedFound { pulse(at: index, color: UIColor(CapyPalette.green), strong: true) }
            for index in addedErrors { pulse(at: index, color: UIColor.systemRed, strong: true) }
            for index in changedMarks { pulse(at: index, color: ink.withAlphaComponent(0.45), strong: false) }
        }
        hasConfigured = true
    }

    /// Presentation-only layers never intercept touches or modify puzzle state.
    private func pulse(at index: Int, color: UIColor, strong: Bool) {
        guard (0..<(size * size)).contains(index), cellSide > 0 else { return }
        let ring = CAShapeLayer()
        ring.frame = rect(for: index).insetBy(dx: cellSide * 0.13, dy: cellSide * 0.13)
        ring.path = UIBezierPath(ovalIn: ring.bounds).cgPath
        ring.fillColor = UIColor.clear.cgColor
        ring.strokeColor = color.cgColor
        ring.lineWidth = strong ? 3 : 1.6
        ring.opacity = 0
        layer.addSublayer(ring)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = strong ? 0.85 : 0.5
        fade.toValue = 0
        let expand = CABasicAnimation(keyPath: "transform.scale")
        expand.fromValue = strong ? 0.60 : 0.35
        expand.toValue = 1.1
        let group = CAAnimationGroup()
        group.animations = [fade, expand]
        group.duration = strong ? 0.30 : 0.20
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(group, forKey: "feedback")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak ring] in ring?.removeFromSuperlayer() }
    }

    private var boardRect: CGRect {
        let side = max(0, min(bounds.width, bounds.height) - 4)
        return CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
    }
    private var cellSide: CGFloat { boardRect.width / CGFloat(size) }
    private func rect(for index: Int) -> CGRect {
        CGRect(x: boardRect.minX + CGFloat(index % size) * cellSide,
               y: boardRect.minY + CGFloat(index / size) * cellSide,
               width: cellSide, height: cellSide)
    }
    private func cell(at point: CGPoint) -> Int? {
        guard boardRect.contains(point), cellSide > 0 else { return nil }
        let col = min(size - 1, Int((point.x - boardRect.minX) / cellSide))
        let row = min(size - 1, Int((point.y - boardRect.minY) / cellSide))
        return row * size + col
    }
    private func region(_ index: Int) -> Int { regions.indices.contains(index) ? regions[index] : 0 }

    @objc private func singleTap(_ gesture: UITapGestureRecognizer) {
        guard !locked, let index = cell(at: gesture.location(in: self)), !found.contains(index), !errors.contains(index) else { return }
        onToggle?(index)
    }
    @objc private func doubleTap(_ gesture: UITapGestureRecognizer) {
        guard !locked, let index = cell(at: gesture.location(in: self)), !found.contains(index), !errors.contains(index) else { return }
        onSubmit?(index)
    }

    @objc private func pan(_ gesture: UIPanGestureRecognizer) {
        guard !locked else { return }
        let location = gesture.location(in: self)
        let movement = gesture.translation(in: self)
        if gesture.state == .began {
            dragStartPoint = CGPoint(x: location.x - movement.x, y: location.y - movement.y)
            dragStart = cell(at: dragStartPoint)
            dragAxis = .pending
            visited.removeAll()
        }
        guard let start = dragStart else { return }
        // End this stroke as soon as the finger leaves the board. Clearing its
        // origin also prevents re-entry from filling the gap back to that origin.
        // Only a new touch (.began) can start another marking stroke.
        guard boardRect.contains(location), gesture.state != .cancelled, gesture.state != .failed else {
            dragStart = nil
            dragAxis = .invalid
            visited.removeAll()
            return
        }
        if gesture.state == .began || gesture.state == .changed || gesture.state == .ended {
            if case .pending = dragAxis, max(abs(movement.x), abs(movement.y)) >= 12 {
                if abs(movement.x) >= abs(movement.y) * 1.65 { dragAxis = .horizontal }
                else if abs(movement.y) >= abs(movement.x) * 1.65 { dragAxis = .vertical }
                else { dragAxis = .invalid }
            }
            var indexes: [Int] = []
            switch dragAxis {
            case .horizontal:
                let column = max(0, min(size - 1, Int(floor((location.x - boardRect.minX) / cellSide))))
                indexes = (min(start % size, column)...max(start % size, column)).map { start / size * size + $0 }
            case .vertical:
                let row = max(0, min(size - 1, Int(floor((location.y - boardRect.minY) / cellSide))))
                indexes = (min(start / size, row)...max(start / size, row)).map { $0 * size + start % size }
            case .pending, .invalid: break
            }
            let fresh = indexes.filter { !visited.contains($0) && !found.contains($0) && !errors.contains($0) }
            visited.formUnion(indexes)
            if !fresh.isEmpty { onMark?(fresh) }
        }
        if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
            dragStart = nil
            visited.removeAll()
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func layoutSubviews() {
        super.layoutSubviews()
        for (index, element) in cells.enumerated() { element.accessibilityFrameInContainerSpace = rect(for: index) }
    }

    private func refreshAccessibility() {
        if cells.count != size * size {
            cells = (0..<(size * size)).map { index in
                let element = PuzzleCellAccessibilityElement(accessibilityContainer: self)
                element.index = index
                element.owner = self
                element.accessibilityIdentifier = "cell_\(index)"
                element.accessibilityCustomActions = [
                    UIAccessibilityCustomAction(name: "Confirm capybara", target: element, selector: #selector(PuzzleCellAccessibilityElement.submit)),
                    UIAccessibilityCustomAction(name: "Toggle exclusion mark", target: element, selector: #selector(PuzzleCellAccessibilityElement.toggle))
                ]
                return element
            }
            accessibilityElements = cells
        }
        for (index, element) in cells.enumerated() {
            let state = found.contains(index) ? "found" : errors.contains(index) ? "error" : marks.contains(index) ? "marked" : "empty"
            element.accessibilityLabel = "Row \(index / size + 1), column \(index % size + 1), region \(region(index) + 1)"
            element.accessibilityValue = state
            let extra = tutorialTargets.contains(index) ? " Tutorial target." : preview.contains(index) ? " Hint preview." : ""
            element.accessibilityHint = errors.contains(index) ? "A permanent mistake marker. It cannot be removed." : "Activate to toggle an exclusion mark. Use the Confirm capybara custom action to submit.\(extra)"
            element.accessibilityTraits = locked || found.contains(index) || errors.contains(index) ? [.button, .notEnabled] : .button
            element.accessibilityFrameInContainerSpace = rect(for: index)
        }
    }

    fileprivate func activate(index: Int, submit: Bool) -> Bool {
        guard !locked, !found.contains(index), !errors.contains(index) else { return false }
        if submit { onSubmit?(index) } else { onToggle?(index) }
        return true
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), cellSide > 0 else { return }
        let board = boardRect
        context.saveGState()
        context.addPath(UIBezierPath(roundedRect: board, cornerRadius: 10).cgPath)
        context.clip()
        for index in 0..<(size * size) {
            let r = self.rect(for: index)
            let paletteIndex = ((region(index) % CapyPalette.regionColors.count) + CapyPalette.regionColors.count) % CapyPalette.regionColors.count
            context.setFillColor(UIColor(CapyPalette.regionColors[paletteIndex]).cgColor)
            context.fill(r)
            if preview.contains(index) {
                context.setFillColor(UIColor.white.withAlphaComponent(0.36).cgColor)
                context.fill(r)
                context.setStrokeColor(UIColor.systemBlue.cgColor)
                context.setLineWidth(2)
                context.setLineDash(phase: 0, lengths: [3, 2])
                context.stroke(r.insetBy(dx: 4, dy: 4))
                context.setLineDash(phase: 0, lengths: [])
            }
            if found.contains(index) { drawCapy(in: r, context: context) }
            else if errors.contains(index) { drawX(in: r, context: context, error: true) }
            else if marks.contains(index) { drawX(in: r, context: context, error: false) }
            if tutorialTargets.contains(index) {
                context.setStrokeColor(UIColor(CapyPalette.orange).cgColor)
                context.setLineWidth(3)
                context.stroke(r.insetBy(dx: 3, dy: 3))
                let dot = CGRect(x: r.maxX - 9, y: r.minY + 4, width: 5, height: 5)
                context.setFillColor(UIColor(CapyPalette.orange).cgColor)
                context.fillEllipse(in: dot)
            }
            // Thin cell lines remain visible inside every irregular region.
            context.setStrokeColor(ink.withAlphaComponent(0.14).cgColor)
            context.setLineWidth(0.6)
            context.stroke(r)
        }
        context.setStrokeColor(ink.withAlphaComponent(0.82).cgColor)
        context.setLineWidth(size >= 9 ? 2 : 2.5)
        context.setLineCap(.square)
        for index in 0..<(size * size) {
            let r = self.rect(for: index)
            if index % size < size - 1 && region(index) != region(index + 1) {
                context.move(to: CGPoint(x: r.maxX, y: r.minY))
                context.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            }
            if index / size < size - 1 && region(index) != region(index + size) {
                context.move(to: CGPoint(x: r.minX, y: r.maxY))
                context.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            }
        }
        context.strokePath()
        context.restoreGState()
        context.setStrokeColor(ink.cgColor)
        context.setLineWidth(2)
        context.addPath(UIBezierPath(roundedRect: board, cornerRadius: 10).cgPath)
        context.strokePath()
    }

    private func drawX(in rect: CGRect, context: CGContext, error: Bool) {
        let r = rect.insetBy(dx: rect.width * 0.31, dy: rect.height * 0.31)
        let color = error ? UIColor(red: 0.78, green: 0.18, blue: 0.15, alpha: 1) : ink.withAlphaComponent(0.65)
        if error {
            context.setFillColor(UIColor.white.withAlphaComponent(0.7).cgColor)
            context.fillEllipse(in: rect.insetBy(dx: rect.width * 0.18, dy: rect.height * 0.18))
        }
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(error ? 3 : 2.2)
        context.setLineCap(.round)
        context.move(to: CGPoint(x: r.minX, y: r.minY))
        context.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        context.move(to: CGPoint(x: r.maxX, y: r.minY))
        context.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        context.strokePath()
    }

    private func drawCapy(in rect: CGRect, context: CGContext) {
        let r = rect.insetBy(dx: rect.width * 0.11, dy: rect.height * 0.10)
        context.saveGState()
        context.translateBy(x: r.minX, y: r.minY)
        context.scaleBy(x: r.width / 100, y: r.height / 100)
        context.setFillColor(UIColor(red: 0.53, green: 0.34, blue: 0.18, alpha: 1).cgColor)
        context.fillEllipse(in: CGRect(x: 13, y: 12, width: 23, height: 28))
        context.fillEllipse(in: CGRect(x: 65, y: 12, width: 23, height: 28))
        context.setFillColor(UIColor(red: 0.70, green: 0.47, blue: 0.27, alpha: 1).cgColor)
        context.addPath(UIBezierPath(roundedRect: CGRect(x: 7, y: 24, width: 86, height: 64), cornerRadius: 27).cgPath)
        context.fillPath()
        context.setFillColor(UIColor(red: 0.83, green: 0.62, blue: 0.40, alpha: 1).cgColor)
        context.fillEllipse(in: CGRect(x: 31, y: 54, width: 52, height: 32))
        context.setFillColor(ink.cgColor)
        context.fillEllipse(in: CGRect(x: 26, y: 46, width: 7, height: 7))
        context.fillEllipse(in: CGRect(x: 66, y: 46, width: 7, height: 7))
        context.fillEllipse(in: CGRect(x: 48, y: 60, width: 18, height: 11))
        context.setStrokeColor(ink.cgColor)
        context.setLineWidth(2.3)
        context.setLineCap(.round)
        context.move(to: CGPoint(x: 53, y: 77))
        context.addQuadCurve(to: CGPoint(x: 66, y: 76), control: CGPoint(x: 61, y: 82))
        context.strokePath()
        context.restoreGState()
    }
}

private final class PuzzleCellAccessibilityElement: UIAccessibilityElement {
    var index = 0
    weak var owner: PuzzleGridUIView?
    override func accessibilityActivate() -> Bool { owner?.activate(index: index, submit: false) ?? false }
    @objc func submit() -> Bool { owner?.activate(index: index, submit: true) ?? false }
    @objc func toggle() -> Bool { owner?.activate(index: index, submit: false) ?? false }
}
