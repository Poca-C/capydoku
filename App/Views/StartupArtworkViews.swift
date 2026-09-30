import SwiftUI

/// Original document [272, 278] / image23: sky, water, a character, then a
/// bottom loading line and logo. Artwork and copy belong to Capydoku.
struct StartupLoadingView: View {
    let isPreparing: Bool
    // Hosted-view branch verification only; production leaves the system value intact.
    let reduceMotionOverride: Bool?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.appLanguage) private var language

    init(isPreparing: Bool, reduceMotionOverride: Bool? = nil) {
        self.isPreparing = isPreparing
        self.reduceMotionOverride = reduceMotionOverride
    }

    var body: some View {
        GeometryReader { geometry in
            let horizontal = max(26, geometry.size.width * 0.085)
            let mascotSize = min(geometry.size.width * 0.57,
                                 geometry.size.height * (dynamicTypeSize.isAccessibilitySize ? 0.23 : 0.28), 224)
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 18) {
                    Text(language.text("Follow the clues.\nFind every capy."))
                        .font(.system(.title, design: .rounded).weight(.bold))
                        // Accessibility sizes wrap down onto the pale sky;
                        // switch to the dark brand ink instead of losing contrast.
                        .foregroundColor(dynamicTypeSize.isAccessibilitySize
                            ? Color(red: 0.03, green: 0.20, blue: 0.28) : .white)
                        .lineLimit(4).minimumScaleFactor(0.65)
                        .fixedSize(horizontal: false, vertical: true)
                        .shadow(color: Color(red: 0.09, green: 0.34, blue: 0.53).opacity(0.2), radius: 1, y: 1)
                    Text("— Capydoku")
                        .font(.system(.body, design: .rounded).weight(.medium))
                        // Larger text sits lower over the pale part of the sky.
                        .foregroundColor(Color(red: 0.03, green: 0.20, blue: 0.28))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.horizontal, horizontal)
                .frame(maxWidth: 500, maxHeight: .infinity, alignment: .center)

                StartupBathingCapy(size: mascotSize)
                    .frame(height: mascotSize * 0.86)
                    .accessibilityHidden(true)

                VStack(spacing: 23) {
                    StartupBusyLine(isPreparing: isPreparing,
                                    foreground: Color(red: 0.72, green: 0.98, blue: 1),
                                    track: Color(red: 0.05, green: 0.48, blue: 0.62),
                                    reduceMotionOverride: reduceMotionOverride)
                    StartupWordmark(waterfront: true)
                }
                .padding(.horizontal, horizontal)
                .padding(.top, 12)
                .padding(.bottom, max(22, geometry.size.height * 0.045))
                .frame(maxWidth: 440)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(StartupWaterfront().ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("loading_stage")
        // The parent owns all flow and permission interactions. These pages
        // remain usable as the visual background of its Welcome overlay.
        .allowsHitTesting(false)
    }
}

/// The second, quiet brand page remains visible behind the permission flow.
/// No health/sleep claim or reference-product brand is carried over.
struct StartupBrandView: View {
    let isPreparing: Bool
    // This optional test input does not claim to exercise the real system switch.
    let reduceMotionOverride: Bool?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.appLanguage) private var language

    init(isPreparing: Bool, reduceMotionOverride: Bool? = nil) {
        self.isPreparing = isPreparing
        self.reduceMotionOverride = reduceMotionOverride
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 18) {
                    Text(language.text("A little logic.\nA lot of capy."))
                        .font(.system(.title, design: .rounded).weight(.bold))
                        .lineLimit(4).minimumScaleFactor(0.65)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("— Capydoku")
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .foregroundColor(CapyPalette.ink)
                .padding(.top, dynamicTypeSize.isAccessibilitySize ? 24 : geometry.size.height * 0.14)
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 24)

                VStack(spacing: 22) {
                    VStack(spacing: 2) {
                        HStack {
                            Spacer()
                            Image("CapyFace").resizable().scaledToFit()
                                .frame(width: 30, height: 30)
                                .padding(.trailing, 15)
                        }.accessibilityHidden(true)
                        StartupBusyLine(isPreparing: isPreparing,
                                        foreground: CapyPalette.orange, track: CapyPalette.line.opacity(0.6),
                                        reduceMotionOverride: reduceMotionOverride)
                    }
                    StartupWordmark(waterfront: false)
                }
                .padding(.bottom, max(28, geometry.size.height * 0.055))
            }
            .padding(.horizontal, max(28, geometry.size.width * 0.09))
            .frame(maxWidth: 500)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(CapyPalette.cream.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("brand_loading_stage")
        .allowsHitTesting(false)
    }
}

private struct StartupWordmark: View {
    let waterfront: Bool
    var body: some View {
        Text("Capydoku")
            .foregroundColor(waterfront ? Color(red: 0.04, green: 0.35, blue: 0.44) : CapyPalette.ink)
            // Fixed lettering is a logo, not body copy; the accessible name
            // remains available independently of its decorative font size.
            .font(.system(size: 37, weight: .black, design: .rounded))
            .tracking(-1.6)
            .lineLimit(1).minimumScaleFactor(0.7)
            .accessibilityLabel("Capydoku")
    }
}

private struct StartupBusyLine: View {
    let isPreparing: Bool
    let foreground: Color
    let track: Color
    let reduceMotionOverride: Bool?
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appLanguage) private var language
    private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }

    var body: some View {
        // Provisional presentation values: 1.8 s sweep, a 32% moving segment,
        // and a 7 pt line. The segment is indeterminate, never loaded percent.
        // No timer here advances the startup controller or completes its work.
        TimelineView(.animation(minimumInterval: 1.0 / 30,
                                paused: !isPreparing || reduceMotion || scenePhase != .active)) { timeline in
            GeometryReader { geometry in
                let width = geometry.size.width
                let segment = width * 0.32
                let phase = CGFloat(timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8)
                let stationary = reduceMotion || scenePhase != .active
                ZStack(alignment: .leading) {
                    Capsule().fill(track)
                    Capsule().fill(foreground)
                        .frame(width: isPreparing ? segment : width)
                        .offset(x: isPreparing ? (stationary ? (width - segment) / 2 : -segment + (width + segment) * phase) : 0)
                }.clipShape(Capsule())
            }
        }
        .frame(height: 7)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(language.text("Loading Capydoku"))
        .accessibilityValue(language.text(isPreparing ? "Preparing" : "Ready"))
    }
}

private struct StartupBathingCapy: View {
    let size: CGFloat
    var body: some View {
        ZStack {
            Ellipse().fill(Color.white.opacity(0.16))
                .frame(width: size * 1.28, height: size * 0.23)
                .offset(y: size * 0.18)
            Image("CapyMascot").resizable().scaledToFit()
                .frame(width: size, height: size)
                // Existing art is seated, not the reference otter's supine pose.
                // Conceal its lower body at the waterline to depict a bathing
                // capybara; do not rotate or stretch it into unrelated artwork.
                .mask(LinearGradient(stops: [.init(color: .white, location: 0),
                                             .init(color: .white, location: 0.62),
                                             .init(color: .clear, location: 0.78)],
                                     startPoint: .top, endPoint: .bottom))
            Ellipse().trim(from: 0.03, to: 0.46)
                .stroke(Color.white.opacity(0.72), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: size * 1.18, height: size * 0.23)
                .offset(y: size * 0.18)
            Ellipse().trim(from: 0.58, to: 0.9)
                .stroke(Color.white.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .frame(width: size * 1.42, height: size * 0.32)
                .offset(y: size * 0.19)
        }
        .frame(width: size * 1.5, height: size)
    }
}

private struct StartupWaterfront: View {
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(stops: [
                    .init(color: Color(red: 0.15, green: 0.48, blue: 0.83), location: 0),
                    .init(color: Color(red: 0.24, green: 0.60, blue: 0.90), location: 0.44),
                    .init(color: Color(red: 0.96, green: 0.75, blue: 0.69), location: 0.61),
                    .init(color: Color(red: 0.49, green: 0.88, blue: 0.93), location: 0.62)
                ], startPoint: .top, endPoint: .bottom)

                Canvas { context, canvas in
                    let width = canvas.width, height = canvas.height
                    // These illustrative proportions/colors are Demo styling,
                    // preserving the reference composition without copying art.
                    let horizon = height * 0.61
                    let clouds: [(CGFloat, CGFloat, CGFloat)] = [(0.08, 0.19, 0.20), (0.86, 0.35, 0.27)]
                    for cloud in clouds {
                        let rect = CGRect(x: width * cloud.0 - width * cloud.2 / 2,
                                          y: height * cloud.1, width: width * cloud.2, height: 15)
                        context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.05)))
                    }
                    var bank = Path()
                    bank.move(to: CGPoint(x: 0, y: horizon))
                    bank.addQuadCurve(to: CGPoint(x: width * 0.58, y: horizon),
                                      control: CGPoint(x: width * 0.24, y: horizon - height * 0.09))
                    bank.addQuadCurve(to: CGPoint(x: width, y: horizon),
                                      control: CGPoint(x: width * 0.80, y: horizon - height * 0.045))
                    bank.closeSubpath()
                    context.fill(bank, with: .color(Color(red: 1, green: 0.82, blue: 0.74).opacity(0.65)))
                    let water = CGRect(x: 0, y: horizon, width: width, height: height - horizon)
                    context.fill(Path(water), with: .linearGradient(Gradient(colors: [
                        Color(red: 0.50, green: 0.89, blue: 0.94),
                        Color(red: 0.06, green: 0.77, blue: 0.87)
                    ]), startPoint: CGPoint(x: 0, y: horizon), endPoint: CGPoint(x: 0, y: height)))
                    var edge = Path()
                    edge.move(to: CGPoint(x: 0, y: horizon + 2))
                    edge.addLine(to: CGPoint(x: width, y: horizon + 2))
                    context.stroke(edge, with: .color(.white.opacity(0.55)), lineWidth: 3)
                    for index in 0..<6 {
                        let y = horizon + 22 + CGFloat(index * index) * 5
                        var wave = Path()
                        wave.move(to: CGPoint(x: -width * 0.08, y: y + 7))
                        wave.addQuadCurve(to: CGPoint(x: width * (index.isMultiple(of: 2) ? 0.95 : 0.75), y: y),
                                          control: CGPoint(x: width * 0.35, y: y - 18))
                        context.stroke(wave, with: .color(.white.opacity(index == 0 ? 0.3 : 0.09)),
                                       style: StrokeStyle(lineWidth: index == 0 ? 3 : 7, lineCap: .round))
                    }
                }
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
