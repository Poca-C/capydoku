import UIKit

/// A short event-driven reaction on an already-found character. There is no
/// idle loop or repeating timer, and the board can remove it at any time.
final class CapyFaceExpressionView: UIView {
    let cellIndex: Int
    let expression: CapyFaceExpression
    let duration: TimeInterval
    private let face = CALayer()
    private var cleanupTask: DispatchWorkItem?

    init(cellIndex: Int, expression: CapyFaceExpression, frame: CGRect,
         tileColor: UIColor, reduceMotion: Bool) {
        self.cellIndex = cellIndex
        self.expression = reduceMotion && expression == .blink ? .neutral : expression
        duration = reduceMotion ? 0.18 : expression == .blink ? 0.14 : 0.42
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false; accessibilityElementsHidden = true
        backgroundColor = tileColor
        layer.cornerRadius = max(3, bounds.width * 0.05)
        face.name = "capy-expression-\(self.expression)"
        face.frame = bounds.insetBy(dx: bounds.width * 0.07, dy: bounds.height * 0.07)
        face.contents = CapyExpressionArtwork.image(self.expression)?.cgImage
        face.contentsGravity = .resizeAspect
        layer.addSublayer(face)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func play() {
        cleanupTask?.cancel()
        let cleanup = DispatchWorkItem { [weak self] in self?.removeFromSuperview() }
        cleanupTask = cleanup
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: cleanup)
    }

    override func willMove(toSuperview newSuperview: UIView?) {
        if newSuperview == nil {
            cleanupTask?.cancel(); cleanupTask = nil
            layer.removeAllAnimations(); face.removeAllAnimations()
        }
        super.willMove(toSuperview: newSuperview)
    }
}
