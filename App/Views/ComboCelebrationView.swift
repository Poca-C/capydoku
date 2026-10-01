import SwiftUI

/// Demo visual tiers only. The existing model/audio mapping still decides when
/// Nice, Great and Excellent occur; styling cannot change scoring or thresholds.
enum ComboVisualTier: Int, CaseIterable {
    case nice, great, excellent
    init(text: String) { self = text == "Excellent" ? .excellent : text == "Great" ? .great : .nice }
    var stars: Int { rawValue + 1 }
    var initialScale: CGFloat { [0.90, 0.78, 0.66][rawValue] }
    var initialAngle: Double { [0, -5, 5][rawValue] }
}

struct ComboCelebrationView: View {
    let text: String
    let tier: ComboVisualTier
    let compact: Bool
    let reduceMotion: Bool
    @State private var arrived = false

    var body: some View {
        HStack(spacing: 5) {
            if tier != .nice { ornaments(reverse: true) }
            HStack(spacing: 4) {
                Image(systemName: tier == .excellent ? "crown.fill" : "star.fill")
                    .font(.system(size: tier == .excellent ? 13 : 10, weight: .black))
                Text(text).font(.system(size: compact ? 16 : 19, weight: .heavy, design: .rounded))
            }
            .foregroundColor(tier == .excellent ? CapyPalette.paper : CapyPalette.actionOrange)
            .padding(.horizontal, tier == .nice ? 8 : 10).padding(.vertical, 1)
            .background(tier == .excellent ? CapyPalette.actionOrange : tier == .great ? CapyPalette.orangeLight : CapyPalette.paper)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(CapyPalette.orange.opacity(tier == .nice ? 0.4 : 0.75), lineWidth: 1))
            .scaleEffect(reduceMotion || arrived ? 1 : tier.initialScale)
            .rotationEffect(.degrees(reduceMotion || arrived ? 0 : tier.initialAngle))
            if tier != .nice { ornaments(reverse: false) }
        }.fixedSize().frame(height: compact ? 22 : 28)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore).accessibilityLabel(text)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.spring(response: tier == .nice ? 0.24 : 0.36, dampingFraction: tier == .excellent ? 0.55 : 0.70)) {
                    arrived = true
                }
            }
    }
    private func ornaments(reverse: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<tier.stars, id: \.self) { index in
                Image(systemName: index == 0 ? "sparkle" : "star.fill")
                    .font(.system(size: index == 0 ? 11 : 6, weight: .bold))
                    .foregroundColor(CapyPalette.orange)
            }
        }.scaleEffect(x: reverse ? -1 : 1, y: 1)
            .opacity(reduceMotion || arrived ? 1 : 0.2)
            .accessibilityHidden(true)
    }
}

/// The press acknowledgement starts with touch-down, even before a paid tool
/// opens its reward UI. It does not predict whether a reveal will succeed.
struct ToolPressStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.capyMotionOverride) private var override
    let direct: Bool
    private var reduceMotion: Bool { override ?? systemReduceMotion }
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(!enabled ? 0.42 : configuration.isPressed ? 0.86 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1)
            .rotationEffect(.degrees(configuration.isPressed && direct && !reduceMotion ? -7 : 0))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
