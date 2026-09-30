import SwiftUI
import UIKit
import CapydokuCore

struct PuzzleBoardView: UIViewRepresentable {
    let puzzle: Puzzle
    let found: Set<Int>
    let marks: Set<Int>
    let errors: Set<Int>
    var sessionID: UUID? = nil
    var lives: Int? = nil
    var effectsEnabled = true
    var preview: Set<Int> = []
    var tutorialTargets: Set<Int> = []
    var hideAccessibility: Bool = false
    let locked: Bool
    let onToggle: (Int) -> Void
    let onSubmit: (Int) -> Void
    let onMark: ([Int]) -> Void
    var onBeginSwipe: () -> Void = {}
    var onEndSwipe: (Bool) -> Void = { _ in }

    func makeUIView(context: Context) -> PuzzleGridUIView {
        let view = PuzzleGridUIView()
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ uiView: PuzzleGridUIView, context: Context) {
        uiView.configure(size: puzzle.size, regions: puzzle.regions, found: found,
                         marks: marks, errors: errors, preview: preview,
                         sessionID: sessionID, lives: lives, effectsEnabled: effectsEnabled,
                         tutorialTargets: tutorialTargets, locked: locked, hideAccessibility: hideAccessibility,
                         onToggle: onToggle, onSubmit: onSubmit, onMark: onMark,
                         onBeginSwipe: onBeginSwipe, onEndSwipe: onEndSwipe)
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
    private var hideAccessibility = false
    private var onToggle: ((Int) -> Void)?
    private var onSubmit: ((Int) -> Void)?
    private var onMark: (([Int]) -> Void)?
    private var onBeginSwipe: (() -> Void)?
    private var onEndSwipe: ((Bool) -> Void)?
    private var swipeFeedbackActive = false
    private var cells: [PuzzleCellAccessibilityElement] = []
    private enum DragAxis { case pending, horizontal, vertical, invalid }
    private var dragAxis: DragAxis = .pending
    private var dragStart: Int?
    private var visited = Set<Int>()
    private var dragStartPoint = CGPoint.zero
    private let ink = UIColor(CapyPalette.ink)
    private var hasConfigured = false
    private var sessionID: UUID?
    private var lives: Int?
    private var pendingSubmission: Int?
    private let feedbackOverlay = UIView()

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
        feedbackOverlay.isUserInteractionEnabled = false
        feedbackOverlay.isAccessibilityElement = false
        feedbackOverlay.accessibilityElementsHidden = true
        addSubview(feedbackOverlay)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(size: Int, regions: [Int], found: Set<Int>, marks: Set<Int>, errors: Set<Int>,
                   preview: Set<Int>, sessionID: UUID? = nil, lives: Int? = nil, effectsEnabled: Bool = true,
                   tutorialTargets: Set<Int>, locked: Bool, hideAccessibility: Bool = false,
                   onToggle: @escaping (Int) -> Void, onSubmit: @escaping (Int) -> Void,
                   onMark: @escaping ([Int]) -> Void,
                   onBeginSwipe: @escaping () -> Void = {}, onEndSwipe: @escaping (Bool) -> Void = { _ in }) {
        let sameBoard = self.size == size && self.regions == regions && self.sessionID == sessionID
        let addedFound = found.subtracting(self.found)
        let addedErrors = errors.subtracting(self.errors)
        let changedMarks = marks.symmetricDifference(self.marks).subtracting(found).subtracting(errors)
        // A red X can be submitted again. Its set membership does not change,
        // so the actual life deduction, not insertion into errors, owns feedback.
        let lostLife = self.lives.map { before in lives.map { $0 < before } ?? false } ?? false
        var mistakeCell: Int?
        if lostLife {
            mistakeCell = pendingSubmission.flatMap { errors.contains($0) ? $0 : nil }
                ?? addedErrors.sorted().first
        } else if self.lives == nil && lives == nil {
            mistakeCell = addedErrors.sorted().first
        }
        if !sameBoard || !effectsEnabled { clearFeedback() }
        for effect in feedbackOverlay.subviews.compactMap({ $0 as? BoardMistakeFeedbackView }) where !errors.contains(effect.cellIndex) {
            effect.removeFromSuperview()
        }
        if !sameBoard || locked {
            finishSwipe(cancelled: true)
            dragStart = nil
            visited.removeAll()
        }
        self.size = max(1, size)
        self.sessionID = sessionID
        self.lives = lives
        pendingSubmission = nil
        self.regions = regions
        self.found = found
        self.marks = marks
        self.errors = errors
        self.preview = preview
        self.tutorialTargets = tutorialTargets
        self.locked = locked
        self.hideAccessibility = hideAccessibility
        accessibilityElementsHidden = hideAccessibility
        self.onToggle = onToggle
        self.onSubmit = onSubmit
        self.onMark = onMark
        self.onBeginSwipe = onBeginSwipe
        self.onEndSwipe = onEndSwipe
        refreshAccessibility()
        setNeedsDisplay()
        if hasConfigured, sameBoard, effectsEnabled, window != nil, !UIAccessibility.isReduceMotionEnabled {
            for index in addedFound { pulse(at: index, color: UIColor(CapyPalette.orange), strong: true); celebrate(at: index) }
            for index in changedMarks { pulse(at: index, color: ink.withAlphaComponent(0.45), strong: false) }
        }
        if hasConfigured, sameBoard, effectsEnabled, window != nil, let index = mistakeCell {
            mistake(at: index)
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
        feedbackOverlay.layer.addSublayer(ring)
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
        let side = max(0, min(bounds.width, bounds.height) - 14)
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
        guard !locked, let index = cell(at: gesture.location(in: self)), !found.contains(index) else { return }
        onToggle?(index)
    }
    @objc private func doubleTap(_ gesture: UITapGestureRecognizer) {
        guard !locked, let index = cell(at: gesture.location(in: self)), !found.contains(index) else { return }
        submit(index)
    }

    private func submit(_ index: Int) {
        pendingSubmission = index
        onSubmit?(index)
    }

    @objc private func pan(_ gesture: UIPanGestureRecognizer) {
        guard !locked else { finishSwipe(cancelled: true); return }
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
            finishSwipe(cancelled: true)
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
                if dragAxis == .horizontal || dragAxis == .vertical {
                    swipeFeedbackActive = true
                    onBeginSwipe?()
                }
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
            finishSwipe(cancelled: gesture.state != .ended)
            dragStart = nil
            visited.removeAll()
        }
    }

    private func finishSwipe(cancelled: Bool) {
        guard swipeFeedbackActive else { return }
        swipeFeedbackActive = false
        onEndSwipe?(cancelled)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { finishSwipe(cancelled: true); clearFeedback(); pendingSubmission = nil }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func layoutSubviews() {
        super.layoutSubviews()
        if feedbackOverlay.bounds.size != bounds.size { clearFeedback() }
        feedbackOverlay.frame = bounds
        for (index, element) in cells.enumerated() { element.accessibilityFrameInContainerSpace = rect(for: index) }
    }

    private func refreshAccessibility() {
        if cells.count != size * size {
            cells = (0..<(size * size)).map { index in
                let element = PuzzleCellAccessibilityElement(accessibilityContainer: self)
                element.index = index
                element.owner = self
                element.accessibilityIdentifier = "cell_\(index)"
                return element
            }
        }
        // SwiftUI's ancestor accessibilityHidden does not reliably hide custom
        // UIAccessibilityElement arrays owned by UIViewRepresentable children.
        accessibilityElements = hideAccessibility ? [] : cells
        for (index, element) in cells.enumerated() {
            let state = found.contains(index) ? "found" : errors.contains(index) ? "error" : marks.contains(index) ? "marked" : "empty"
            element.accessibilityLabel = "Row \(index / size + 1), column \(index % size + 1), region \(region(index) + 1)"
            element.accessibilityValue = state
            let extra = tutorialTargets.contains(index) ? " Tutorial target." : preview.contains(index) ? " Hint preview." : ""
            element.accessibilityHint = locked ? "Read-only board preview.\(extra)" : "Activate to toggle an exclusion mark. Use the Confirm capybara custom action to submit.\(extra)"
            element.accessibilityCustomActions = locked || found.contains(index) ? nil : [
                UIAccessibilityCustomAction(name: "Confirm capybara", target: element, selector: #selector(PuzzleCellAccessibilityElement.submit)),
                UIAccessibilityCustomAction(name: "Toggle exclusion mark", target: element, selector: #selector(PuzzleCellAccessibilityElement.toggle))
            ]
            element.accessibilityTraits = locked || found.contains(index) ? [.button, .notEnabled] : .button
            element.accessibilityFrameInContainerSpace = rect(for: index)
        }
    }

    @discardableResult func activate(index: Int, submit: Bool) -> Bool {
        guard !locked, (0..<(size * size)).contains(index), !found.contains(index) else { return false }
        if submit { self.submit(index) } else { onToggle?(index) }
        return true
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), cellSide > 0 else { return }
        let board = boardRect
        (preview.isEmpty ? UIColor.white : UIColor.white.withAlphaComponent(0.22)).setFill()
        UIBezierPath(roundedRect: board.insetBy(dx: -6, dy: -6), cornerRadius: 12).fill()
        let gap = max(1.1, min(2, cellSide * 0.028))
        for index in 0..<(size * size) {
            let r = self.rect(for: index).insetBy(dx: gap, dy: gap)
            let paletteIndex = ((region(index) % CapyPalette.regionColors.count) + CapyPalette.regionColors.count) % CapyPalette.regionColors.count
            let fill = UIColor(CapyPalette.regionColors[paletteIndex])
            let tile = UIBezierPath(roundedRect: r, cornerRadius: max(3, cellSide * 0.05))
            fill.setFill(); tile.fill()
            if found.contains(index) { drawCapy(in: r, context: context) }
            else if errors.contains(index) { drawX(in: r, context: context, error: true) }
            else if marks.contains(index) { drawX(in: r, context: context, error: false) }
            if !preview.isEmpty {
                if preview.contains(index) {
                    // An outlined X is a preview only; no exclusion enters the saved state.
                    drawX(in: r, context: context, error: false, previewFill: fill)
                } else {
                    UIColor.black.withAlphaComponent(0.66).setFill(); tile.fill()
                }
            }
            if tutorialTargets.contains(index) {
                context.setStrokeColor(UIColor(CapyPalette.orange).cgColor)
                context.setLineWidth(3)
                context.addPath(UIBezierPath(roundedRect: r.insetBy(dx: 2, dy: 2), cornerRadius: 5).cgPath)
                context.strokePath()
                let dot = CGRect(x: r.maxX - 10, y: r.minY + 5, width: 6, height: 6)
                context.setFillColor(UIColor(CapyPalette.orange).cgColor); context.fillEllipse(in: dot)
            }
        }
    }

    private func drawX(in rect: CGRect, context: CGContext, error: Bool, previewFill: UIColor? = nil) {
        let r = rect.insetBy(dx: rect.width * 0.23, dy: rect.height * 0.23)
        func stroke(_ color: UIColor, width: CGFloat) {
            context.setStrokeColor(color.cgColor); context.setLineWidth(width); context.setLineCap(.round)
            context.move(to: CGPoint(x: r.minX, y: r.minY)); context.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            context.move(to: CGPoint(x: r.maxX, y: r.minY)); context.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            context.strokePath()
        }
        let width = max(3.2, rect.width * 0.11)
        stroke(error ? UIColor(CapyPalette.life) : .white, width: width)
        if let previewFill { stroke(previewFill, width: max(1, width - 2.6)) }
    }

    private func celebrate(at index: Int) {
        let cell = rect(for: index)
        if let image = UIImage(named: "CapyFace") {
            let face = UIImageView(image: image); face.contentMode = .scaleAspectFit
            face.frame = cell.insetBy(dx: cell.width * 0.07, dy: cell.height * 0.07)
            face.isUserInteractionEnabled = false; feedbackOverlay.addSubview(face)
            face.transform = CGAffineTransform(scaleX: 0.65, y: 0.65)
            UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.5, initialSpringVelocity: 0.4) { face.transform = .identity } completion: { _ in face.removeFromSuperview() }
        }
        for number in 0..<5 {
            let star = UIImageView(image: UIImage(systemName: "star.fill")); star.tintColor = UIColor(CapyPalette.orange)
            star.frame = CGRect(x: cell.midX - 5, y: cell.midY - 5, width: 10, height: 10)
            feedbackOverlay.addSubview(star)
            let angle = CGFloat(number) * .pi * 2 / 5
            UIView.animate(withDuration: 0.48, animations: {
                star.center = CGPoint(x: cell.midX + cos(angle) * cell.width * 0.65, y: cell.midY + sin(angle) * cell.height * 0.65)
                star.alpha = 0; star.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
            }, completion: { _ in star.removeFromSuperview() })
        }
    }

    private func mistake(at index: Int) {
        guard (0..<(size * size)).contains(index), cellSide > 0 else { return }
        // Replace the same-cell transient effect. Rapid valid mistakes must not
        // stack several opaque hearts over the player's latest state.
        for view in feedbackOverlay.subviews.compactMap({ $0 as? BoardMistakeFeedbackView }) where view.cellIndex == index {
            view.removeFromSuperview()
        }
        let palette = ((region(index) % CapyPalette.regionColors.count) + CapyPalette.regionColors.count) % CapyPalette.regionColors.count
        let gap = max(1.1, min(2, cellSide * 0.028))
        let effect = BoardMistakeFeedbackView(cellIndex: index, frame: rect(for: index).insetBy(dx: gap, dy: gap),
                                             tileColor: UIColor(CapyPalette.regionColors[palette]),
                                             reduceMotion: UIAccessibility.isReduceMotionEnabled)
        feedbackOverlay.addSubview(effect)
        effect.play()
    }

    private func clearFeedback() {
        feedbackOverlay.subviews.forEach { $0.removeFromSuperview() }
        feedbackOverlay.layer.sublayers?.forEach { $0.removeFromSuperlayer() }
    }

    private func drawCapy(in rect: CGRect, context: CGContext) {
        if let image = UIImage(named: "CapyFace") {
            image.draw(in: rect.insetBy(dx: rect.width * 0.07, dy: rect.height * 0.07)); return
        }
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
