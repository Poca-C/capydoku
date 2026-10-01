import SwiftUI

/// Acknowledgement is the only action here. The transparent hole exposes the
/// real HUD, while the full-screen button prevents a dismissal tap becoming a move.
struct LastLifeSpotlightView: View {
    @Environment(\.appLanguage) private var language
    @ScaledMetric(relativeTo: .headline) private var titleSize: CGFloat = 21
    @ScaledMetric(relativeTo: .subheadline) private var captionSize: CGFloat = 15
    let livesFrame: CGRect
    let dismiss: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let hole = Self.focusFrame(livesFrame, in: geometry.size)
            CapyButton(id: "last_life_continue", action: dismiss) {
                ZStack(alignment: .top) {
                    SpotlightMask(hole: hole).fill(Color.black.opacity(0.68), style: FillStyle(eoFill: true))
                    Capsule().stroke(CapyPalette.orangeLight, lineWidth: 3)
                        .frame(width: hole.width, height: hole.height).position(x: hole.midX, y: hole.midY)
                    VStack(spacing: 0) {
                        Image(systemName: "arrowtriangle.up.fill").font(.system(size: 18))
                            .foregroundColor(CapyPalette.paper)
                            .offset(x: min(90, max(-90, hole.midX - geometry.size.width / 2)))
                        VStack(spacing: 12) {
                            HStack(spacing: 8) {
                                Image(systemName: "heart.fill").foregroundColor(CapyPalette.life)
                                Text(language.text("Only one chance left!"))
                            }.font(.system(size: min(titleSize, 30), weight: .heavy, design: .rounded))
                            Text(language.text("Take a breath. Check the row, column and color before your next find."))
                                .font(.system(size: min(captionSize, 23), weight: .medium, design: .rounded))
                            Text(language.text("Tap anywhere to continue"))
                                .font(.system(size: min(captionSize, 23), weight: .bold, design: .rounded))
                                .foregroundColor(CapyPalette.actionOrange)
                        }.multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                            .foregroundColor(CapyPalette.ink).padding(20)
                            .frame(maxWidth: 330).background(CapyPalette.paper)
                            .clipShape(RoundedRectangle(cornerRadius: 22))
                            .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
                    }.padding(.horizontal, 22).padding(.top, hole.maxY + 8)
                }.frame(width: geometry.size.width, height: geometry.size.height)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel(language.text("Only one chance left!"))
                .accessibilityHint(language.text("Tap anywhere to continue"))
                .accessibilityIdentifier("last_life_continue").capyFocus("last_life_continue")
                .capyLayoutProbe("last_life_continue")
                .accessibilityAddTraits(.isModal)
        }
    }

    static func focusFrame(_ frame: CGRect, in size: CGSize) -> CGRect {
        let valid = !frame.isEmpty && [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite)
        let source = valid ? frame.insetBy(dx: -7, dy: -5) : CGRect(x: size.width / 2 - 45, y: 110, width: 90, height: 38)
        let width = min(max(1, size.width - 16), source.width)
        let height = min(58, max(1, source.height))
        return CGRect(x: min(max(8, source.minX), max(8, size.width - width - 8)),
                      y: min(max(8, source.minY), max(8, size.height * 0.36 - height)),
                      width: width, height: height)
    }
}

private struct SpotlightMask: Shape {
    let hole: CGRect
    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addRoundedRect(in: hole, cornerSize: CGSize(width: hole.height / 2, height: hole.height / 2))
        return path
    }
}
