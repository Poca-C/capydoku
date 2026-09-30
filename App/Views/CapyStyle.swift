import SwiftUI
import UIKit

/// Theme values follow the cream, orange and brown palette in the original specification.
enum CapyPalette {
    static let cream = Color(red: 0.97, green: 0.95, blue: 0.93)
    static let paper = Color(red: 1.00, green: 0.99, blue: 0.97)
    static let ink = Color(red: 0.49, green: 0.31, blue: 0.29)
    static let orange = Color(red: 0.97, green: 0.56, blue: 0.08)
    // Functional labels/buttons need contrast; decorative artwork keeps the reference orange.
    static let actionOrange = Color(red: 0.72, green: 0.30, blue: 0.015)
    // Functional text colors for Original [306]. White ON/OFF text has 8.23:1
    // and 8.56:1 contrast on these tracks (4.92:1 / 4.99:1 while pressed).
    // The decorative green, line and orange colors remain unchanged.
    static let switchOnTrack = Color(red: 0.14, green: 0.35, blue: 0.18)
    static let switchOffTrack = Color(red: 0.37, green: 0.28, blue: 0.23)
    // 5.33:1 against cream; actionOrange is 4.64:1 against the same page.
    static let checkInSecondaryText = Color(red: 0.35, green: 0.40, blue: 0.43)
    static let orangeLight = Color(red: 0.98, green: 0.88, blue: 0.77)
    static let muted = Color(red: 0.62, green: 0.45, blue: 0.41)
    static let green = Color(red: 0.24, green: 0.64, blue: 0.31)
    static let video = Color(red: 0.03, green: 0.73, blue: 0.32)
    static let life = Color(red: 0.94, green: 0.24, blue: 0.22)
    static let disabled = Color(red: 0.65, green: 0.68, blue: 0.67)
    static let line = Color(red: 0.88, green: 0.78, blue: 0.70)
    static let regionColors: [Color] = [
        Color(red: 0.23, green: 0.66, blue: 0.74),
        Color(red: 0.81, green: 0.44, blue: 0.57),
        Color(red: 0.98, green: 0.84, blue: 0.49),
        Color(red: 0.76, green: 0.63, blue: 0.07),
        Color(red: 0.53, green: 0.75, blue: 0.45),
        Color(red: 0.54, green: 0.47, blue: 0.83),
        Color(red: 0.24, green: 0.57, blue: 0.37),
        Color(red: 0.67, green: 0.44, blue: 0.30),
        Color(red: 0.57, green: 0.74, blue: 0.90),
        Color(red: 0.91, green: 0.57, blue: 0.83)
    ]
}

enum CapyMood { case neutral, happy, sad }

struct CapyMascot: View {
    var mood: CapyMood = .neutral
    var size: CGFloat = 100

    var body: some View {
        Group {
            if let artwork = UIImage(named: mood == .sad ? "CapySad" : size > 90 ? "CapyMascot" : "CapyFace") {
                Image(uiImage: artwork).resizable().scaledToFit()
            } else { drawnFace }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }

    private var drawnFace: some View {
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
    var darkBackdrop: Bool = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 16 : 25, weight: .heavy, design: .rounded))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, compact ? 18 : 26)
            .padding(.vertical, compact ? 10 : 14)
            .frame(minWidth: 44, minHeight: compact ? 44 : 60)
            .foregroundColor(secondary ? (darkBackdrop ? CapyPalette.orange : CapyPalette.actionOrange) : .white)
            .background(secondary ? Color.clear : CapyPalette.actionOrange)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(secondary ? CapyPalette.orange : .clear, lineWidth: 1.5))
            .shadow(color: secondary ? .clear : CapyPalette.orange.opacity(0.22), radius: 5, y: 3)
            .opacity(isEnabled ? (configuration.isPressed ? 0.86 : 1) : 0.42)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.13), value: configuration.isPressed)
    }
}

struct CapyPressStyle: ButtonStyle {
    // A disabled check-in date is a persistent status, so it keeps its full
    // claimed/unclaimed artwork while remaining genuinely non-interactive.
    var disabledOpacity: Double = 0.45
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : disabledOpacity)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.93 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct CapyButtonActivationKey: EnvironmentKey {
    static let defaultValue: (String?) -> Void = { _ in }
}

private struct CapyAccessibilityFocusKey: EnvironmentKey {
    static let defaultValue: AccessibilityFocusState<String?>.Binding? = nil
}

extension EnvironmentValues {
    var capyButtonActivation: (String?) -> Void {
        get { self[CapyButtonActivationKey.self] }
        set { self[CapyButtonActivationKey.self] = newValue }
    }
    var capyAccessibilityFocus: AccessibilityFocusState<String?>.Binding? {
        get { self[CapyAccessibilityFocusKey.self] }
        set { self[CapyAccessibilityFocusKey.self] = newValue }
    }
}

/// Feedback belongs to the completed Button action, never to its pressed visual state.
struct CapyButton<Label: View>: View {
    @Environment(\.capyButtonActivation) private var activate
    var id: String? = nil
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    var body: some View {
        Button { activate(id); action() } label: { label().contentShape(Rectangle()) }
            .capyFocus(id)
    }
}

/// Resolve the title in the live view environment so an open sheet or a cached
/// button label responds immediately when the app language changes.
struct CapyButtonLabel: View {
    @Environment(\.appLanguage) private var language
    let title: String
    var body: some View { Text(language.text(title)) }
}

extension CapyButton where Label == CapyButtonLabel {
    init(_ title: String, id: String? = nil, action: @escaping () -> Void) {
        self.id = id; self.action = action; self.label = { CapyButtonLabel(title: title) }
    }
}

private struct CapyFocusModifier: ViewModifier {
    @Environment(\.capyAccessibilityFocus) private var focus
    let id: String?
    @ViewBuilder func body(content: Content) -> some View {
        if let focus, let id { content.accessibilityFocused(focus, equals: id) }
        else { content }
    }
}

extension View {
    func capyFocus(_ id: String?) -> some View { modifier(CapyFocusModifier(id: id)) }
}

/// A real UIKit boundary keeps an entire covered SwiftUI page out of the
/// accessibility tree while retaining the frozen visual background beneath it.
struct CapyAccessibilityHost<Content: View>: UIViewControllerRepresentable {
    let hidden: Bool
    let content: Content
    init(hidden: Bool, @ViewBuilder content: () -> Content) {
        self.hidden = hidden; self.content = content()
    }
    func makeUIViewController(context: Context) -> CapyAccessibilityController<Content> {
        CapyAccessibilityController(content: content)
    }
    func updateUIViewController(_ controller: CapyAccessibilityController<Content>, context: Context) {
        controller.host.rootView = content
        controller.view.accessibilityElementsHidden = hidden
        controller.view.accessibilityElements = hidden ? [] : [controller.host.view!]
        controller.view.isUserInteractionEnabled = !hidden
    }
}

final class CapyAccessibilityController<Content: View>: UIViewController {
    let host: UIHostingController<Content>
    init(content: Content) { host = UIHostingController(rootView: content); super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear; view.isAccessibilityElement = false
        host.view.backgroundColor = .clear
        addChild(host); view.addSubview(host.view); host.didMove(toParent: self)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
}

struct PawBackground: View {
    var body: some View {
        GeometryReader { geometry in
            ForEach(0..<9, id: \.self) { index in
                Image(systemName: "pawprint.fill")
                    .font(.system(size: 29 + CGFloat(index % 3) * 8))
                    .rotationEffect(.degrees(Double(index * 47)))
                    .foregroundColor(CapyPalette.orange.opacity(0.035))
                    .position(x: geometry.size.width * [0.03, 0.91, 0.35, 0.78, 0.06, 0.91, 0.20, 0.67, 0.05][index],
                              y: geometry.size.height * [0.08, 0.10, 0.22, 0.39, 0.49, 0.63, 0.78, 0.93, 0.97][index])
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct CapySectionLabel: View {
    @Environment(\.appLanguage) private var language
    let eyebrow: String
    let title: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(language.text(eyebrow)).font(.system(size: 11, weight: .bold, design: .rounded)).tracking(2).foregroundColor(CapyPalette.orange)
            Text(language.text(title)).font(.system(size: 25, weight: .bold, design: .rounded)).foregroundColor(CapyPalette.ink)
        }
    }
}
