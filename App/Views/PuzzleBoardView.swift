import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import CapydokuCore

struct PuzzleBoardView: UIViewRepresentable {
    @Environment(\.appLanguage) private var language
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.capyMotionOverride) private var motionOverride
    private var reduceMotion: Bool { motionOverride ?? systemReduceMotion }
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
    var onInputActivityChange: (UUID, Bool) -> Void = { _, _ in }
    /// The point is in the board's UIWindow coordinates, not local grid space.
    var onFoundFeedback: (Int, CGPoint) -> Void = { _, _ in }

    func makeUIView(context: Context) -> PuzzleGridUIView {
        let view = PuzzleGridUIView()
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ uiView: PuzzleGridUIView, context: Context) {
        uiView.configure(size: puzzle.size, regions: puzzle.regions, found: found,
                         marks: marks, errors: errors, preview: preview,
                         sessionID: sessionID, lives: lives, effectsEnabled: effectsEnabled,
                         reduceMotion: reduceMotion,
                         tutorialTargets: tutorialTargets, locked: locked, hideAccessibility: hideAccessibility,
                         language: language,
                         onToggle: onToggle, onSubmit: onSubmit, onMark: onMark,
                         onBeginSwipe: onBeginSwipe, onEndSwipe: onEndSwipe,
                         onInputActivityChange: onInputActivityChange,
                         onFoundFeedback: onFoundFeedback)
    }

    static func dismantleUIView(_ uiView: PuzzleGridUIView, coordinator: ()) {
        uiView.cancelInputActivity()
    }
}

/// UIKit resets a recognizer only after its recognition attempt reaches a
/// terminal state. In particular, touchesEnded is too early for double taps.
/// https://developer.apple.com/documentation/uikit/uigesturerecognizer/reset()
private final class BoardActivityTapRecognizer: UITapGestureRecognizer {
    private let activityID = UUID()
    weak var activity: BoardInputActivity?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        activity?.begin(activityID)
        super.touchesBegan(touches, with: event)
    }

    override func reset() {
        super.reset()
        activity?.end(activityID)
    }
}

private final class BoardActivityPanRecognizer: UIPanGestureRecognizer {
    private let activityID = UUID()
    weak var activity: BoardInputActivity?
    var onContactBegan: ((CGPoint) -> Void)?
    var onContactMoved: ((CGPoint) -> Void)?
    var onContactEnded: (() -> Void)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        activity?.begin(activityID)
        if let touch = touches.first, let view { onContactBegan?(touch.location(in: view)) }
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first, let view { onContactMoved?(touch.location(in: view)) }
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        onContactEnded?()
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        onContactEnded?()
        super.touchesCancelled(touches, with: event)
    }

    override func reset() {
        super.reset()
        onContactEnded?()
        activity?.end(activityID)
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
    private var language: AppLanguage = .simplifiedChinese
    private var onToggle: ((Int) -> Void)?
    private var onSubmit: ((Int) -> Void)?
    private var onMark: (([Int]) -> Void)?
    private var onBeginSwipe: (() -> Void)?
    private var onEndSwipe: ((Bool) -> Void)?
    private var onInputActivityChange: ((UUID, Bool) -> Void)?
    private var onFoundFeedback: ((Int, CGPoint) -> Void)?
    let inputActivity = BoardInputActivity()
    private var inputRecognizers: [UIGestureRecognizer] = []
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
    private var pressFeedback: BoardPressedCellView?
    private var trackingContact = false
    private var effectsEnabled = true
    private var reduceMotionOverride: Bool?
    private var applicationAllowsPresentation = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isMultipleTouchEnabled = false
        isAccessibilityElement = false
        accessibilityIdentifier = "puzzle_board"
        inputActivity.onChange = { [weak self] owner, busy in self?.onInputActivityChange?(owner, busy) }
        let single = BoardActivityTapRecognizer(target: self, action: #selector(singleTap(_:)))
        let double = BoardActivityTapRecognizer(target: self, action: #selector(doubleTap(_:)))
        single.activity = inputActivity
        double.activity = inputActivity
        double.numberOfTapsRequired = 2
        single.require(toFail: double)
        let pan = BoardActivityPanRecognizer(target: self, action: #selector(pan(_:)))
        pan.activity = inputActivity
        // Observe the existing pan recognizer's raw contacts; do not add a
        // recognizer, change its thresholds or alter double-tap precedence.
        pan.onContactBegan = { [weak self] in self?.beginCellPress(at: $0) }
        pan.onContactMoved = { [weak self] in self?.moveCellPress(to: $0) }
        pan.onContactEnded = { [weak self] in self?.endCellPress() }
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        addGestureRecognizer(single)
        addGestureRecognizer(double)
        addGestureRecognizer(pan)
        inputRecognizers = [single, double, pan]
        updateInputAvailability()
        contentMode = .redraw
        feedbackOverlay.isUserInteractionEnabled = false
        feedbackOverlay.isAccessibilityElement = false
        feedbackOverlay.accessibilityElementsHidden = true
        addSubview(feedbackOverlay)
        NotificationCenter.default.addObserver(self, selector: #selector(suspendBoardPresentation), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resumeBoardPresentation), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reduceMotionChanged), name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(size: Int, regions: [Int], found: Set<Int>, marks: Set<Int>, errors: Set<Int>,
                   preview: Set<Int>, sessionID: UUID? = nil, lives: Int? = nil, effectsEnabled: Bool = true,
                   reduceMotion: Bool? = nil,
                   tutorialTargets: Set<Int>, locked: Bool, hideAccessibility: Bool = false,
                   language: AppLanguage = .simplifiedChinese,
                   onToggle: @escaping (Int) -> Void, onSubmit: @escaping (Int) -> Void,
                   onMark: @escaping ([Int]) -> Void,
                   onBeginSwipe: @escaping () -> Void = {}, onEndSwipe: @escaping (Bool) -> Void = { _ in },
                   onInputActivityChange: @escaping (UUID, Bool) -> Void = { _, _ in },
                   onFoundFeedback: @escaping (Int, CGPoint) -> Void = { _, _ in }) {
        let sameBoard = self.size == size && self.regions == regions && self.sessionID == sessionID
        let addedFound = found.subtracting(self.found)
        let addedErrors = errors.subtracting(self.errors)
        let removedErrors = self.errors.subtracting(errors)
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
        let motionPolicyChanged = reducesMotion != (reduceMotion ?? UIAccessibility.isReduceMotionEnabled)
        if !sameBoard || !effectsEnabled || motionPolicyChanged { clearFeedback() }
        for effect in feedbackOverlay.subviews.compactMap({ $0 as? BoardCellFeedbackView }) {
            let valid = effect.kind == .found ? found.contains(effect.cellIndex)
                : effect.kind == .markAdded ? marks.contains(effect.cellIndex) && !found.contains(effect.cellIndex) && !errors.contains(effect.cellIndex)
                : !marks.contains(effect.cellIndex) && !found.contains(effect.cellIndex) && !errors.contains(effect.cellIndex)
            if !valid { effect.removeFromSuperview() }
        }
        for effect in feedbackOverlay.subviews.compactMap({ $0 as? BoardMistakeFeedbackView }) where !errors.contains(effect.cellIndex) {
            effect.removeFromSuperview()
        }
        if !sameBoard || locked {
            // Disable the actual recognizers as well as clearing our ledger:
            // an old tap must not arrive after a new session has been unlocked.
            self.locked = true
            cancelInputActivity()
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
        self.language = language
        self.effectsEnabled = effectsEnabled
        self.reduceMotionOverride = reduceMotion
        accessibilityElementsHidden = hideAccessibility
        self.onToggle = onToggle
        self.onSubmit = onSubmit
        self.onMark = onMark
        self.onBeginSwipe = onBeginSwipe
        self.onEndSwipe = onEndSwipe
        // Cancellation above must notify the outgoing session's callback.
        // Only subsequent attempts belong to this updated board configuration.
        self.onInputActivityChange = onInputActivityChange
        self.onFoundFeedback = onFoundFeedback
        if let pressed = pressFeedback?.cellIndex, !canPress(pressed) { endCellPress() }
        updateInputAvailability()
        refreshAccessibility()
        setNeedsDisplay()
        if hasConfigured, sameBoard, canPresentEffects {
            for index in addedFound.sorted() where (0..<(size * size)).contains(index) {
                cellFeedback(at: index, kind: .found)
                if let window {
                    let cell = rect(for: index)
                    self.onFoundFeedback?(index, convert(CGPoint(x: cell.midX, y: cell.midY), to: window))
                }
            }
            for index in changedMarks.sorted() {
                cellFeedback(at: index, kind: marks.contains(index) ? .markAdded : .markRemoved,
                             errorMark: removedErrors.contains(index))
            }
        }
        if hasConfigured, sameBoard, canPresentEffects, let index = mistakeCell {
            mistake(at: index)
        }
        hasConfigured = true
    }

    private var canPresentEffects: Bool {
        effectsEnabled && applicationAllowsPresentation && window != nil && window?.isHidden == false && !isHidden && alpha > 0
    }

    private var reducesMotion: Bool { reduceMotionOverride ?? UIAccessibility.isReduceMotionEnabled }

    private func canPress(_ index: Int) -> Bool {
        canPresentEffects && !locked && !hideAccessibility && preview.isEmpty && !found.contains(index)
            && (tutorialTargets.isEmpty || tutorialTargets.contains(index))
    }

    /// Called from raw contacts on the existing pan recognizer, before either
    /// tap is recognized. These methods only own a transient highlight.
    func beginCellPress(at point: CGPoint) {
        endCellPress()
        guard let index = cell(at: point), canPress(index) else { return }
        trackingContact = true
        showCellPress(index)
    }

    func moveCellPress(to point: CGPoint) {
        guard trackingContact else { return }
        guard let index = cell(at: point) else { endCellPress(); return }
        guard canPress(index) else { pressFeedback?.removeFromSuperview(); pressFeedback = nil; return }
        showCellPress(index)
    }

    func endCellPress() {
        trackingContact = false
        pressFeedback?.removeFromSuperview(); pressFeedback = nil
    }

    private func showCellPress(_ index: Int) {
        guard pressFeedback?.cellIndex != index else { return }
        pressFeedback?.removeFromSuperview()
        let gap = max(1.1, min(2, cellSide * 0.028))
        let view = BoardPressedCellView(cellIndex: index, frame: rect(for: index).insetBy(dx: gap, dy: gap))
        feedbackOverlay.addSubview(view); pressFeedback = view
    }

    private func cellFeedback(at index: Int, kind: BoardCellFeedbackView.Kind, errorMark: Bool = false) {
        guard (0..<(size * size)).contains(index), cellSide > 0 else { return }
        for effect in feedbackOverlay.subviews.compactMap({ $0 as? BoardCellFeedbackView }) where effect.cellIndex == index { effect.removeFromSuperview() }
        let palette = ((region(index) % CapyPalette.regionColors.count) + CapyPalette.regionColors.count) % CapyPalette.regionColors.count
        let gap = max(1.1, min(2, cellSide * 0.028))
        let effect = BoardCellFeedbackView(cellIndex: index, kind: kind,
            frame: rect(for: index).insetBy(dx: gap, dy: gap), tileColor: UIColor(CapyPalette.regionColors[palette]),
            reduceMotion: reducesMotion, errorMark: errorMark)
        feedbackOverlay.addSubview(effect); effect.play()
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
        guard gesture.state == .recognized, !locked, let index = cell(at: gesture.location(in: self)), !found.contains(index) else { return }
        onToggle?(index)
    }
    @objc private func doubleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .recognized, !locked, let index = cell(at: gesture.location(in: self)), !found.contains(index) else { return }
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
            // A found animal is not an operable origin, just as it cannot
            // receive a single tap. Crossing one later still skips that cell.
            if let start = dragStart, found.contains(start) { dragStart = nil }
            dragAxis = .pending
            visited.removeAll()
        }
        guard let start = dragStart else { return }
        // End this stroke as soon as the finger leaves the board. Clearing its
        // origin also prevents re-entry from filling the gap back to that origin.
        // Only a new touch (.began) can start another marking stroke.
        guard boardRect.contains(location), gesture.state != .cancelled, gesture.state != .failed else {
            invalidateSwipePath()
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
                // Original [133] marks only cells the finger passes through
                // along one row/column. Do not project a turn onto the old row.
                guard let current = cell(at: location), current / size == start / size else {
                    invalidateSwipePath(); return
                }
                let column = max(0, min(size - 1, Int(floor((location.x - boardRect.minX) / cellSide))))
                indexes = (min(start % size, column)...max(start % size, column)).map { start / size * size + $0 }
            case .vertical:
                guard let current = cell(at: location), current % size == start % size else {
                    invalidateSwipePath(); return
                }
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

    private func invalidateSwipePath() {
        endCellPress()
        finishSwipe(cancelled: true)
        dragStart = nil
        dragAxis = .invalid
        visited.removeAll()
    }

    private func finishSwipe(cancelled: Bool) {
        guard swipeFeedbackActive else { return }
        swipeFeedbackActive = false
        onEndSwipe?(cancelled)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancelInputActivity(); clearFeedback(); pendingSubmission = nil }
        else { updateInputAvailability() }
    }

    func cancelInputActivity() {
        endCellPress()
        for recognizer in inputRecognizers where recognizer.isEnabled { recognizer.isEnabled = false }
        finishSwipe(cancelled: true)
        dragStart = nil
        dragAxis = .pending
        visited.removeAll()
        inputActivity.cancelAll()
    }

    private func updateInputAvailability() {
        let enabled = !locked && window != nil && applicationAllowsPresentation
        for recognizer in inputRecognizers where recognizer.isEnabled != enabled { recognizer.isEnabled = enabled }
    }

    @objc private func suspendBoardPresentation() {
        applicationAllowsPresentation = false
        cancelInputActivity()
        clearFeedback()
        pendingSubmission = nil
    }

    @objc private func resumeBoardPresentation() {
        applicationAllowsPresentation = true
        updateInputAvailability()
        // Resuming never replays a found cell or changes the saved board.
    }

    @objc private func reduceMotionChanged() {
        clearFeedback()
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
            let position = language.text("Row \(index / size + 1), column \(index % size + 1), region \(region(index) + 1)")
            // Keep the existing machine-readable state used by UI tests. The
            // Chinese label also speaks the state without relying on that token.
            element.accessibilityLabel = language == .simplifiedChinese ? position + "，" + language.text(state) : position
            element.accessibilityValue = state
            let extra = tutorialTargets.contains(index) ? language.text("Tutorial target.") : preview.contains(index) ? language.text("Hint preview.") : ""
            let instruction = language.text(locked ? "Read-only board preview." : "Activate to toggle an exclusion mark. Use the Confirm capybara custom action to submit.")
            element.accessibilityHint = [instruction, extra].filter { !$0.isEmpty }.joined(separator: language == .simplifiedChinese ? "" : " ")
            element.accessibilityCustomActions = locked || found.contains(index) ? nil : [
                UIAccessibilityCustomAction(name: language.text("Confirm capybara"), target: element, selector: #selector(PuzzleCellAccessibilityElement.submit)),
                UIAccessibilityCustomAction(name: language.text("Toggle exclusion mark"), target: element, selector: #selector(PuzzleCellAccessibilityElement.toggle))
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
        // Original [244]: keep the white X while giving light region colors a
        // readable boundary. The same 1pt edge protects the red error marker;
        // the preview's colored center remains hollow and unapplied.
        stroke(UIColor(CapyPalette.markOutline), width: width + 2)
        stroke(error ? UIColor(CapyPalette.life) : .white, width: width)
        if let previewFill { stroke(previewFill, width: max(1, width - 2.6)) }
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
                                             reduceMotion: reducesMotion)
        feedbackOverlay.addSubview(effect)
        effect.play()
    }

    private func clearFeedback() {
        endCellPress()
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
