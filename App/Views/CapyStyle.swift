import SwiftUI

/// Original, code-drawn visual language for this internal demo.
enum CapyPalette {
    static let cream = Color(red: 0.98, green: 0.96, blue: 0.91)
    static let paper = Color(red: 1.00, green: 0.99, blue: 0.96)
    static let ink = Color(red: 0.27, green: 0.22, blue: 0.17)
    static let orange = Color(red: 0.91, green: 0.43, blue: 0.22)
    static let orangeLight = Color(red: 0.99, green: 0.88, blue: 0.72)
    static let muted = Color(red: 0.53, green: 0.50, blue: 0.43)
    static let green = Color(red: 0.30, green: 0.46, blue: 0.36)
    static let line = Color(red: 0.87, green: 0.84, blue: 0.76)
    static let regionColors: [Color] = [
        Color(red: 0.99, green: 0.86, blue: 0.66),
        Color(red: 0.80, green: 0.89, blue: 0.74),
        Color(red: 0.73, green: 0.85, blue: 0.94),
        Color(red: 0.94, green: 0.77, blue: 0.80),
        Color(red: 0.86, green: 0.80, blue: 0.95),
        Color(red: 0.98, green: 0.92, blue: 0.66),
        Color(red: 0.71, green: 0.89, blue: 0.84),
        Color(red: 0.96, green: 0.80, blue: 0.69),
        Color(red: 0.80, green: 0.83, blue: 0.72),
        Color(red: 0.88, green: 0.83, blue: 0.80)
    ]
}

enum CapyMood { case neutral, happy, sad }

struct CapyMascot: View {
    var mood: CapyMood = .neutral
    var size: CGFloat = 100

    var body: some View {
        Canvas { context, canvas in
            let scale = min(canvas.width, canvas.height) / 100
            context.scaleBy(x: scale, y: scale)
            func ellipse(_ rect: CGRect, _ color: Color) {
                context.fill(Path(ellipseIn: rect), with: .color(color))
            }
            let fur = Color(red: 0.70, green: 0.48, blue: 0.29)
            let shade = Color(red: 0.54, green: 0.35, blue: 0.20)
            ellipse(CGRect(x: 10, y: 84, width: 80, height: 10), CapyPalette.ink.opacity(0.07))
            ellipse(CGRect(x: 19, y: 19, width: 22, height: 28), shade)
            ellipse(CGRect(x: 60, y: 19, width: 22, height: 28), shade)
            ellipse(CGRect(x: 24, y: 24, width: 12, height: 16), Color(red: 0.84, green: 0.65, blue: 0.45))
            ellipse(CGRect(x: 65, y: 24, width: 12, height: 16), Color(red: 0.84, green: 0.65, blue: 0.45))
            let head = Path(roundedRect: CGRect(x: 13, y: 29, width: 74, height: 59), cornerRadius: 26)
            context.fill(head, with: .color(fur))
            ellipse(CGRect(x: 30, y: 58, width: 48, height: 28), Color(red: 0.80, green: 0.59, blue: 0.38))
            ellipse(CGRect(x: 47, y: 62, width: 15, height: 9), CapyPalette.ink)
            if mood == .happy {
                for x: CGFloat in [32, 65] {
                    var eye = Path()
                    eye.move(to: CGPoint(x: x - 4, y: 53))
                    eye.addQuadCurve(to: CGPoint(x: x + 4, y: 53), control: CGPoint(x: x, y: 47))
                    context.stroke(eye, with: .color(CapyPalette.ink), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                }
            } else {
                ellipse(CGRect(x: 30, y: 49, width: 5, height: mood == .sad ? 3.5 : 5), CapyPalette.ink)
                ellipse(CGRect(x: 65, y: 49, width: 5, height: mood == .sad ? 3.5 : 5), CapyPalette.ink)
            }
            var mouth = Path()
            mouth.move(to: CGPoint(x: 49, y: 76))
            mouth.addQuadCurve(to: CGPoint(x: 61, y: 76), control: CGPoint(x: 55, y: mood == .sad ? 71 : 81))
            context.stroke(mouth, with: .color(CapyPalette.ink), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            ellipse(CGRect(x: 24, y: 60, width: 10, height: 5), CapyPalette.orange.opacity(0.32))
            ellipse(CGRect(x: 70, y: 60, width: 10, height: 5), CapyPalette.orange.opacity(0.32))
            // A little orange makes the capybara silhouette our own.
            ellipse(CGRect(x: 43, y: 15, width: 20, height: 18), CapyPalette.orange)
            var leaf = Path()
            leaf.move(to: CGPoint(x: 53, y: 17))
            leaf.addQuadCurve(to: CGPoint(x: 64, y: 9), control: CGPoint(x: 53, y: 6))
            leaf.addQuadCurve(to: CGPoint(x: 53, y: 17), control: CGPoint(x: 64, y: 18))
            context.fill(leaf, with: .color(CapyPalette.green))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct CapyCard<Content: View>: View {
    var padding: CGFloat = 18
    private let content: Content
    init(padding: CGFloat = 18, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }
    var body: some View {
        content.padding(padding)
            .background(CapyPalette.paper)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(CapyPalette.line.opacity(0.75), lineWidth: 1))
    }
}

struct CapyButtonStyle: ButtonStyle {
    var secondary: Bool = false
    var compact: Bool = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 14 : 17, weight: .bold, design: .rounded))
            .padding(.horizontal, compact ? 16 : 22)
            .frame(minHeight: compact ? 44 : 54)
            .foregroundColor(secondary ? CapyPalette.ink : .white)
            .background(secondary ? CapyPalette.orangeLight : CapyPalette.orange)
            .clipShape(RoundedRectangle(cornerRadius: compact ? 15 : 18, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.42)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

struct CapySectionLabel: View {
    let eyebrow: String
    let title: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(eyebrow).font(.system(size: 11, weight: .bold, design: .rounded)).tracking(2).foregroundColor(CapyPalette.orange)
            Text(title).font(.system(size: 25, weight: .bold, design: .rounded)).foregroundColor(CapyPalette.ink)
        }
    }
}
