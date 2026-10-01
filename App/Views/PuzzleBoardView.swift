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
    var entranceID: UUID? = nil
    var lives: Int? = nil
    var score: Int? = nil
    var effectsEnabled = true
    var preview: Set<Int> = []
    var tutorialTargets: Set<Int> = []
    var tutorialAction: String? = nil
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
    var onConflictFeedback: ([VisibleConflictKind]) -> Void = { _ in }
    var onScoreFeedback: (Int, CGPoint) -> Void = { _, _ in }

    func makeUIView(context: Context) -> PuzzleGridUIView {
        let view = PuzzleGridUIView()
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ uiView: PuzzleGridUIView, context: Context) {
        uiView.configure(size: puzzle.size, regions: puzzle.regions, found: found,
                         marks: marks, errors: errors, preview: preview,
                         sessionID: sessionID, entranceID: entranceID, lives: lives, score: score, effectsEnabled: effectsEnabled,
                         reduceMotion: reduceMotion,
                         tutorialTargets: tutorialTargets, tutorialAction: tutorialAction, locked: locked, hideAccessibility: hideAccessibility,
                         language: language,
                         onToggle: onToggle, onSubmit: onSubmit, onMark: onMark,
                         onBeginSwipe: onBeginSwipe, onEndSwipe: onEndSwipe,
                         onInputActivityChange: onInputActivityChange,
                         onFoundFeedback: onFoundFeedback, onConflictFeedback: onConflictFeedback,
                         onScoreFeedback: onScoreFeedback)
    }

    static func dismantleUIView(_ uiView: PuzzleGridUIView, coordinator: ()) {
        uiView.cancelPresentation()
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
    /// Read-only work counters for hosted efficiency checks, never gameplay state.
    struct RefreshDiagnostics: Equatable {
        var configurations = 0
        var accessibilityPasses = 0
        var updatedAccessibilityCells = 0
        var customActionsCreated = 0
        var displayInvalidations = 0
        var geometryCellUpdates = 0
    }
    private(set) var refreshDiagnostics = RefreshDiagnostics()
    private var size = 4
    private var regions: [Int] = []
    private var found = Set<Int>()
    private var marks = Set<Int>()
    private var errors = Set<Int>()
    private var preview = Set<Int>()
    private var tutorialTargets = Set<Int>()
    private var tutorialAction: String?
    private var tutorialGuide: BoardTutorialGuideView?
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
    private var onConflictFeedback: (([VisibleConflictKind]) -> Void)?
    private var onScoreFeedback: ((Int, CGPoint) -> Void)?
    let inputActivity = BoardInputActivity()
    private var inputRecognizers: [UIGestureRecognizer] = []
    private var swipeFeedbackActive = false
    private var cells: [PuzzleCellAccessibilityElement] = []
    private var accessibilityGeometry: CGRect?
    private enum DragAxis { case pending, horizontal, vertical, invalid }
    private var dragAxis: DragAxis = .pending
    private var dragStart: Int?
    private var visited = Set<Int>()
    private var dragStartPoint = CGPoint.zero
    private let ink = UIColor(CapyPalette.ink)
    private var hasConfigured = false
    private var sessionID: UUID?
    private var consumedEntranceIDs = Set<UUID>()
    private var pendingEntranceID: UUID?
    private var lives: Int?
    private var score: Int?
    private var pendingSubmission: Int?
    private let feedbackOverlay = UIView()
    private var pressFeedback: BoardPressedCellView?
    private var trackingContact = false
    private var effectsEnabled = true
    private var reduceMotionOverride: Bool?
    private var applicationAllowsPresentation = true
    // One cancellable job for the whole board, rather than one timer per animal.
    // Injectable only for deterministic host tests; no gameplay state depends on it.
    var idleBlinkScheduler: (TimeInterval, DispatchWorkItem) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    private var idleBlinkJob: DispatchWorkItem?
    private var idleBlinkToken = UUID()
    private var lastBlinkedCell: Int?
    private var idleReactionOrdinal = 0

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
        NotificationCenter.default.addObserver(self, selector: #selector(scenePowerModeChanged), name: .NSProcessInfoPowerStateDidChange, object: nil)
    }

    deinit { idleBlinkJob?.cancel(); NotificationCenter.default.removeObserver(self) }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(size: Int, regions: [Int], found: Set<Int>, marks: Set<Int>, errors: Set<Int>,
                   preview: Set<Int>, sessionID: UUID? = nil, entranceID: UUID? = nil, lives: Int? = nil, score: Int? = nil, effectsEnabled: Bool = true,
                   reduceMotion: Bool? = nil,
                   tutorialTargets: Set<Int>, tutorialAction: String? = nil, locked: Bool, hideAccessibility: Bool = false,
                   language: AppLanguage = .simplifiedChinese,
                   onToggle: @escaping (Int) -> Void, onSubmit: @escaping (Int) -> Void,
                   onMark: @escaping ([Int]) -> Void,
                   onBeginSwipe: @escaping () -> Void = {}, onEndSwipe: @escaping (Bool) -> Void = { _ in },
                   onInputActivityChange: @escaping (UUID, Bool) -> Void = { _, _ in },
                   onFoundFeedback: @escaping (Int, CGPoint) -> Void = { _, _ in },
                   onConflictFeedback: @escaping ([VisibleConflictKind]) -> Void = { _ in },
                   onScoreFeedback: @escaping (Int, CGPoint) -> Void = { _, _ in }) {
        refreshDiagnostics.configurations += 1
        let sameBoard = self.size == size && self.regions == regions && self.sessionID == sessionID
        let fullAccessibilityRefresh = !hasConfigured || !sameBoard || self.language != language || self.locked != locked
        let changedAccessibilityCells = found.symmetricDifference(self.found)
            .union(marks.symmetricDifference(self.marks)).union(errors.symmetricDifference(self.errors))
            .union(preview.symmetricDifference(self.preview)).union(tutorialTargets.symmetricDifference(self.tutorialTargets))
        let refreshAccessibilityVisibility = self.hideAccessibility != hideAccessibility
        let redrawBoard = !hasConfigured || !sameBoard || self.found != found || self.marks != marks
            || self.errors != errors || self.preview != preview || self.tutorialTargets != tutorialTargets
        let addedFound = found.subtracting(self.found)
        let addedErrors = errors.subtracting(self.errors)
        let removedErrors = self.errors.subtracting(errors)
        let changedMarks = marks.symmetricDifference(self.marks).subtracting(found).subtracting(errors)
        let becameComplete = hasConfigured && sameBoard && self.found.count < size && found.count == size
            && !addedFound.isEmpty && found.allSatisfy { (0..<(size * size)).contains($0) }
        let scoreDelta = self.score.flatMap { before in score.map { $0 - before } } ?? 0
        let scoreOrigin = pendingSubmission.flatMap { addedFound.contains($0) ? $0 : nil } ?? addedFound.sorted().last
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
        if (locked && tutorialAction != "read") || hideAccessibility || !preview.isEmpty || !addedFound.isEmpty || !changedMarks.isEmpty || !addedErrors.isEmpty {
            clearEntrancePresentation()
        }
        if !preview.isEmpty || (hideAccessibility && found.count != size) { clearScenePresentation() }
        if locked || hideAccessibility || !preview.isEmpty { clearGuidance() }
        for effect in feedbackOverlay.subviews.compactMap({ $0 as? BoardCellFeedbackView }) {
            let valid = effect.kind == .found ? found.contains(effect.cellIndex)
                : effect.kind == .markAdded ? marks.contains(effect.cellIndex) && !found.contains(effect.cellIndex) && !errors.contains(effect.cellIndex)
                : !marks.contains(effect.cellIndex) && !found.contains(effect.cellIndex) && !errors.contains(effect.cellIndex)
            if !valid { effect.removeFromSuperview() }
        }
        for effect in feedbackOverlay.subviews.compactMap({ $0 as? BoardMistakeFeedbackView }) where !errors.contains(effect.cellIndex) {
            effect.removeFromSuperview()
        }
        var clearedConflict = false
        for effect in feedbackOverlay.subviews.compactMap({ $0 as? BoardConflictFeedbackView }) where !errors.contains(effect.candidate) {
            let participants = Set(effect.conflicts.map(\.otherCell))
            effect.removeFromSuperview(); clearedConflict = true
            feedbackOverlay.subviews.compactMap { $0 as? CapyFaceExpressionView }
                .filter { $0.expression == .startled && participants.contains($0.cellIndex) }
                .forEach { $0.removeFromSuperview() }
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
        self.score = score
        pendingSubmission = nil
        self.regions = regions
        self.found = found
        self.marks = marks
        self.errors = errors
        self.preview = preview
        self.tutorialTargets = tutorialTargets
        self.tutorialAction = tutorialAction
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
        self.onConflictFeedback = onConflictFeedback
        self.onScoreFeedback = onScoreFeedback
        if clearedConflict { self.onConflictFeedback?([]) }
        if let pressed = pressFeedback?.cellIndex, !canPress(pressed) { endCellPress() }
        updateInputAvailability()
        // Clock/HUD/closure updates do not change any board pixels or spoken
        // cell state. Keep callbacks fresh without rebuilding every cell action.
        if fullAccessibilityRefresh || refreshAccessibilityVisibility || !changedAccessibilityCells.isEmpty {
            refreshAccessibility(indices: fullAccessibilityRefresh ? nil : changedAccessibilityCells)
        }
        if redrawBoard { refreshDiagnostics.displayInvalidations += 1; setNeedsDisplay() }
        updateTutorialGuide()
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
            if scoreDelta > 0, let index = scoreOrigin, let window {
                let cell = rect(for: index)
                self.onScoreFeedback?(scoreDelta, convert(CGPoint(x: cell.midX, y: cell.midY), to: window))
            }
        }
        if hasConfigured, sameBoard, canPresentEffects, let index = mistakeCell {
            mistake(at: index)
            if !locked && !hideAccessibility && preview.isEmpty { explainMistake(at: index) }
        }
        if becameComplete, canPresentEffects, preview.isEmpty {
            presentScene(.victory, finishingCells: addedFound)
        }
        hasConfigured = true
        receiveEntranceEvent(entranceID)
        updateIdleBlinkScheduling()
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
        removeIdleExpressions()
        clearEntrancePresentation()
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
        removeIdleExpressions()
        for effect in feedbackOverlay.subviews.compactMap({ $0 as? BoardCellFeedbackView }) where effect.cellIndex == index { effect.removeFromSuperview() }
        let palette = ((region(index) % CapyPalette.regionColors.count) + CapyPalette.regionColors.count) % CapyPalette.regionColors.count
        let gap = max(1.1, min(2, cellSide * 0.028))
        let effect = BoardCellFeedbackView(cellIndex: index, kind: kind,
            frame: rect(for: index).insetBy(dx: gap, dy: gap), tileColor: UIColor(CapyPalette.regionColors[palette]),
            reduceMotion: reducesMotion, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            errorMark: errorMark)
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
        clearEntrancePresentation()
        onToggle?(index)
    }
    @objc private func doubleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .recognized, !locked, let index = cell(at: gesture.location(in: self)), !found.contains(index) else { return }
        submit(index)
    }

    private func submit(_ index: Int) {
        clearEntrancePresentation()
        pendingSubmission = index
        onSubmit?(index)
    }

    @objc private func pan(_ gesture: UIPanGestureRecognizer) {
        guard !locked else { finishSwipe(cancelled: true); return }
        let location = gesture.location(in: self)
        let movement = gesture.translation(in: self)
        if gesture.state == .began {
            clearEntrancePresentation()
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
        else { updateInputAvailability(); updateTutorialGuide(); updateIdleBlinkScheduling(); presentPendingEntranceIfPossible() }
    }

    func cancelPresentation() {
        cancelInputActivity(); clearFeedback(); pendingSubmission = nil
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
        updateTutorialGuide()
        updateIdleBlinkScheduling()
        // Resuming never replays a found cell or changes the saved board.
    }

    @objc private func reduceMotionChanged() {
        clearFeedback()
        updateTutorialGuide()
        updateIdleBlinkScheduling()
    }

    @objc private func scenePowerModeChanged() {
        // Dropping an in-flight decoration is preferable to replaying it with
        // a new policy; the underlying board already contains the final state.
        clearScenePresentation()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func layoutSubviews() {
        super.layoutSubviews()
        if feedbackOverlay.bounds.size != bounds.size {
            let mountingEntrance = pendingEntranceID
            clearFeedback()
            pendingEntranceID = mountingEntrance
        }
        feedbackOverlay.frame = bounds
        updateTutorialGuide()
        updateIdleBlinkScheduling()
        presentPendingEntranceIfPossible()
        if accessibilityGeometry != boardRect {
            for (index, element) in cells.enumerated() { element.accessibilityFrameInContainerSpace = rect(for: index) }
            refreshDiagnostics.geometryCellUpdates += cells.count
            accessibilityGeometry = boardRect
        }
    }

    private func refreshAccessibility(indices: Set<Int>? = nil) {
        refreshDiagnostics.accessibilityPasses += 1
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
        let indicesToUpdate = indices?.sorted() ?? Array(cells.indices)
        for index in indicesToUpdate where cells.indices.contains(index) {
            let element = cells[index]
            refreshDiagnostics.updatedAccessibilityCells += 1
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
            if !locked && !found.contains(index) { refreshDiagnostics.customActionsCreated += 2 }
            element.accessibilityTraits = locked || found.contains(index) ? [.button, .notEnabled] : .button
            element.accessibilityFrameInContainerSpace = rect(for: index)
        }
        if indices == nil { accessibilityGeometry = boardRect }
    }

    @discardableResult func activate(index: Int, submit: Bool) -> Bool {
        guard !locked, (0..<(size * size)).contains(index), !found.contains(index) else { return false }
        clearEntrancePresentation()
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
        removeIdleExpressions()
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
        pendingEntranceID = nil
        cancelIdleBlink()
        lastBlinkedCell = nil
        idleReactionOrdinal = 0
        endCellPress()
        feedbackOverlay.subviews.forEach { $0.removeFromSuperview() }
        feedbackOverlay.layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        tutorialGuide = nil
    }

    private func clearGuidance() {
        tutorialGuide?.removeFromSuperview(); tutorialGuide = nil
        feedbackOverlay.subviews.filter { $0 is BoardConflictFeedbackView || $0 is CapyFaceExpressionView || $0 is CapyIdleGazeView }.forEach { $0.removeFromSuperview() }
    }

    private func clearEntrancePresentation() {
        pendingEntranceID = nil
        feedbackOverlay.subviews.compactMap { $0 as? BoardSceneFeedbackView }
            .filter { $0.kind == .entrance }.forEach { $0.removeFromSuperview() }
    }

    private func clearScenePresentation() {
        pendingEntranceID = nil
        feedbackOverlay.subviews.compactMap { $0 as? BoardSceneFeedbackView }.forEach { $0.removeFromSuperview() }
    }

    private func receiveEntranceEvent(_ event: UUID?) {
        guard let event else { pendingEntranceID = nil; return }
        guard consumedEntranceIDs.insert(event).inserted else { return }
        // A newly made UIView may receive its event before its first window or
        // layout. Keep only that mounting case; covered/background events expire.
        guard applicationAllowsPresentation, effectsEnabled, !hideAccessibility, preview.isEmpty,
              !locked || tutorialAction == "read", !isHidden, alpha > 0 else { return }
        pendingEntranceID = event
        presentPendingEntranceIfPossible()
    }

    private func presentPendingEntranceIfPossible() {
        guard pendingEntranceID != nil else { return }
        guard window != nil, cellSide > 0, feedbackOverlay.bounds.size == bounds.size else { return }
        pendingEntranceID = nil
        guard canPresentEffects, !hideAccessibility, preview.isEmpty, !locked || tutorialAction == "read" else { return }
        presentScene(.entrance)
    }

    private func presentScene(_ kind: BoardSceneFeedbackView.Kind, finishingCells: Set<Int> = []) {
        guard cellSide > 0 else { return }
        clearScenePresentation()
        let effect = BoardSceneFeedbackView(kind: kind, frame: bounds, boardRect: boardRect, size: size,
            regions: regions, found: found, finishingCells: finishingCells, reduceMotion: reducesMotion,
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
        // Existing last-cell pop stays on top of the board-wide celebration.
        feedbackOverlay.insertSubview(effect, at: 0); effect.play()
    }

    private var canPresentIdleBlink: Bool {
        hasConfigured && canPresentEffects && !locked && !hideAccessibility && preview.isEmpty
            && tutorialAction == nil && tutorialTargets.isEmpty && !reducesMotion && !found.isEmpty
    }

    private func removeIdleExpressions() {
        feedbackOverlay.subviews.filter {
            ($0 as? CapyFaceExpressionView)?.expression == .blink || $0 is CapyIdleGazeView
        }.forEach { $0.removeFromSuperview() }
    }

    private func cancelIdleBlink() {
        idleBlinkToken = UUID(); idleBlinkJob?.cancel(); idleBlinkJob = nil
        removeIdleExpressions()
    }

    private func updateIdleBlinkScheduling() {
        guard canPresentIdleBlink else { cancelIdleBlink(); return }
        // Repeated SwiftUI updates neither postpone the next blink nor create
        // another scheduled job. A new attempt starts only after this one ends.
        guard idleBlinkJob == nil else { return }
        let token = UUID(); idleBlinkToken = token
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.idleBlinkToken == token else { return }
            self.idleBlinkJob = nil
            self.presentIdleBlinkIfPossible()
            self.updateIdleBlinkScheduling()
        }
        idleBlinkJob = work; idleBlinkScheduler(4, work)
    }

    private func presentIdleBlinkIfPossible() {
        guard canPresentIdleBlink, !trackingContact, !inputActivity.isBusy,
              !feedbackOverlay.subviews.contains(where: {
                  $0 is BoardCellFeedbackView || $0 is BoardMistakeFeedbackView
                      || $0 is BoardConflictFeedbackView || $0 is CapyFaceExpressionView || $0 is CapyIdleGazeView || $0 is BoardSceneFeedbackView
              }) else { return }
        let ordered = found.sorted()
        guard let index = ordered.first(where: { $0 > (lastBlinkedCell ?? -1) }) ?? ordered.first else { return }
        lastBlinkedCell = index
        let palette = ((region(index) % CapyPalette.regionColors.count) + CapyPalette.regionColors.count) % CapyPalette.regionColors.count
        let gap = max(1.1, min(2, cellSide * 0.028))
        let frame = rect(for: index).insetBy(dx: gap, dy: gap)
        let color = UIColor(CapyPalette.regionColors[palette])
        // Alternate a tiny blink with an occasional look. The existing one-job
        // cadence is unchanged; direction/animal order never depends on answers.
        if idleReactionOrdinal.isMultiple(of: 2) {
            let blink = CapyFaceExpressionView(cellIndex: index, expression: .blink,
                frame: frame, tileColor: color, reduceMotion: false)
            feedbackOverlay.addSubview(blink); blink.play()
        } else {
            let look = CapyIdleGazeView(cellIndex: index,
                direction: idleReactionOrdinal == 1 ? .left : .right,
                frame: frame, tileColor: color, reduceMotion: false)
            feedbackOverlay.addSubview(look); look.play()
        }
        idleReactionOrdinal = (idleReactionOrdinal + 1) % 4
    }

    private func updateTutorialGuide() {
        guard applicationAllowsPresentation, window != nil, window?.isHidden == false, !isHidden, alpha > 0,
              !hideAccessibility, preview.isEmpty, !tutorialTargets.isEmpty,
              let action = tutorialAction, ["read", "tap", "swipe", "doubleTap"].contains(action),
              !locked || action == "read", cellSide > 0 else {
            tutorialGuide?.removeFromSuperview(); tutorialGuide = nil; return
        }
        let staticGuide = reducesMotion || !effectsEnabled
        if let current = tutorialGuide, current.action == action, current.targetCells == tutorialTargets,
           current.boardRect == boardRect, current.reduceMotion == staticGuide { return }
        tutorialGuide?.removeFromSuperview()
        let guide = BoardTutorialGuideView(frame: bounds, boardRect: boardRect, size: size,
                                          targetCells: tutorialTargets, action: action, reduceMotion: staticGuide)
        feedbackOverlay.insertSubview(guide, at: 0); tutorialGuide = guide; guide.play()
    }

    private func explainMistake(at index: Int) {
        // This API deliberately receives no Puzzle/solution. An incorrect
        // guess with no conflict against a visible animal gets no invented reason.
        let conflicts = VisibleConflictAnalysis.conflicts(size: size, regions: regions, candidate: index, found: found)
        feedbackOverlay.subviews.compactMap { $0 as? BoardConflictFeedbackView }.forEach { $0.removeFromSuperview() }
        let kinds = Set(conflicts.flatMap(\.kinds))
        // An empty explanation clears the previous rule emphasis as well.
        onConflictFeedback?([.region, .row, .column, .adjacent].filter { kinds.contains($0) })
        guard !conflicts.isEmpty else { return }
        let explanation = BoardConflictFeedbackView(frame: bounds, boardRect: boardRect, size: size,
            regions: regions, candidate: index, conflicts: conflicts, reduceMotion: reducesMotion)
        feedbackOverlay.addSubview(explanation); explanation.play()
        for other in Set(conflicts.map(\.otherCell)).sorted() {
            feedbackOverlay.subviews.compactMap { $0 as? CapyFaceExpressionView }
                .filter { $0.cellIndex == other }.forEach { $0.removeFromSuperview() }
            let palette = ((region(other) % CapyPalette.regionColors.count) + CapyPalette.regionColors.count) % CapyPalette.regionColors.count
            let gap = max(1.1, min(2, cellSide * 0.028))
            let expression = CapyFaceExpressionView(cellIndex: other, expression: .startled,
                frame: rect(for: other).insetBy(dx: gap, dy: gap),
                tileColor: UIColor(CapyPalette.regionColors[palette]), reduceMotion: reducesMotion)
            // Keep explanation outlines above the reacting animal.
            feedbackOverlay.insertSubview(expression, belowSubview: explanation); expression.play()
        }
    }

    private func drawCapy(in rect: CGRect, context: CGContext) {
        if let image = CapyExpressionArtwork.image(.neutral) {
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
