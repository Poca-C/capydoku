import SwiftUI

/// A brief receipt for an already committed tool use, not a delayed action.
struct DirectToolRevealView: View {
    let reveal: GameRewardPresentation.ToolReveal
    @State private var arrived = false
    var body: some View {
        ZStack {
            if !reveal.reduceMotion {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 23, weight: .bold))
                    .foregroundColor(CapyPalette.actionOrange)
                    .padding(5).background(CapyPalette.paper.opacity(0.92)).clipShape(Circle())
                    .scaleEffect(arrived ? 0.65 : 1)
                    .rotationEffect(.degrees(arrived ? 12 : -16))
                    .position(arrived ? reveal.destination : reveal.origin)
                    .opacity(arrived ? 0 : 1)
            }
            Image(systemName: "viewfinder.circle")
                .font(.system(size: 34, weight: .semibold))
                .foregroundColor(CapyPalette.actionOrange)
                .shadow(color: .white, radius: 1)
                .scaleEffect(reveal.reduceMotion ? 1 : arrived ? 1.18 : 0.65)
                .opacity(reveal.reduceMotion ? 0.9 : arrived ? 0 : 1)
                .position(reveal.destination)
        }.allowsHitTesting(false).accessibilityHidden(true)
            .onAppear {
                guard !reveal.reduceMotion else { return }
                withAnimation(.easeOut(duration: 0.48)) { arrived = true }
            }
    }
}
