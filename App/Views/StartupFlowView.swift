import SwiftUI

struct StartupFlowView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @StateObject private var controller: StartupController
    @State private var legalTitle: String?
    private let scenePhaseOverride: ScenePhase?
    private let reduceMotionOverride: Bool?
    private var active: Bool { (scenePhaseOverride ?? scenePhase) == .active }
    private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }

    init(directory: URL) {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let skip = StartupController.shouldSkipForTests(arguments: arguments, environment: ProcessInfo.processInfo.environment)
        #else
        let skip = false
        #endif
        _controller = StateObject(wrappedValue: StartupController(directory: directory, skip: skip))
        scenePhaseOverride = nil
        reduceMotionOverride = nil
    }
    /// Hosts the actual flow with controlled lifecycle and permission adapters in tests.
    init(controller: StartupController, scenePhaseOverride: ScenePhase? = nil, reduceMotionOverride: Bool? = nil) {
        _controller = StateObject(wrappedValue: controller)
        self.scenePhaseOverride = scenePhaseOverride
        self.reduceMotionOverride = reduceMotionOverride
    }
    var body: some View {
        ZStack {
            if controller.stage == .ready { RootView() }
            else {
                Group {
                    if controller.stage == .loading { StartupLoadingView(isPreparing: true) }
                    else { StartupBrandView(isPreparing: controller.stage == .brandLoading) }
                }
                .accessibilityHidden(controller.stage == .welcome || controller.errorMessage != nil)
            }
            // This persistent, independent layer keeps only the Welcome card
            // in its removal transition. Brand and Home never inherit it.
            ZStack {
                if controller.stage == .welcome {
                    Color.black.opacity(0.65).ignoresSafeArea().transition(.opacity)
                    welcomeCard.transition(reduceMotion ? .opacity : .scale(scale: 0.88).combined(with: .opacity))
                }
            }
            // Original [253]; same provisional values as the other Demo cards,
            // not a claim about the missing frozen reference's animation timing.
            .animation(active && !reduceMotion ? .easeOut(duration: 0.18) : nil, value: controller.stage == .welcome)
            // Changing lifecycle/accessibility context disposes any in-flight
            // visual transition, without touching the controller or consent.
            .id(StartupWelcomePresentationIdentity(active: active, reduceMotion: reduceMotion))
            .transaction { transaction in
                if !active || reduceMotion { transaction.animation = nil; transaction.disablesAnimations = true }
            }
            .allowsHitTesting(active && controller.stage == .welcome)
            .accessibilityHidden(controller.stage != .welcome)
        }
        .task {
            controller.onAccepted = { model.consentAccepted() }
            controller.onReady = { model.startupReady() }
            controller.setActive((scenePhaseOverride ?? scenePhase) == .active)
            await controller.begin()
        }
        .onChange(of: scenePhase) { phase in
            let active = (scenePhaseOverride ?? phase) == .active
            controller.setActive(active)
            // A disappeared view may have cancelled its task. Resume only a
            // stopped flow; begin() coalesces any request still in progress.
            if active && controller.errorMessage == nil { Task { await controller.begin() } }
        }
        .sheet(isPresented: Binding(get: { legalTitle != nil }, set: { if !$0 { legalTitle = nil } })) {
            NavigationView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(model.progress.settings.language.text("Internal demo")).font(.title2.bold())
                        Text(model.progress.settings.language.text("The publisher has not supplied the final \(legalTitle ?? "legal document") for this internal build."))
                        Text(model.progress.settings.language.text("This build stores game progress on this device. It does not connect to live advertising or analytics services. Accept continues the internal demo only."))
                    }.padding(24)
                }.navigationTitle(model.progress.settings.language.text(legalTitle ?? "")).navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(model.progress.settings.language.text("Close")) { legalTitle = nil } } }
            }
        }
        .alert(model.progress.settings.language.text("Unable to continue"), isPresented: Binding(get: { controller.errorMessage != nil }, set: { if !$0 { controller.errorMessage = nil } })) {
            Button(model.progress.settings.language.text("Try Again")) {
                controller.errorMessage = nil
                Task { await controller.begin() }
            }
        } message: { Text(model.progress.settings.language.text(controller.errorMessage ?? "")) }
        .environment(\.appLanguage, model.progress.settings.language)
        .environment(\.locale, Locale(identifier: model.progress.settings.language.localeIdentifier))
    }

    private var welcomeCard: some View {
        VStack(spacing: 0) {
            Text(model.progress.settings.language.text("Welcome")).font(.system(size: 26, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity).padding(14).background(Color.orange.opacity(0.10))
            VStack(spacing: 6) {
                Text(model.progress.settings.language.text("Please read and accept our"))
                Button { legalTitle = "Terms of Service" } label: { Text(model.progress.settings.language.text("Terms of Service")).underline() }
                    .buttonStyle(StartupWelcomeButtonStyle())
                Text(model.progress.settings.language.text("and"))
                Button { legalTitle = "Privacy Policy" } label: { Text(model.progress.settings.language.text("Privacy Policy")).underline() }
                    .buttonStyle(StartupWelcomeButtonStyle())
            }.font(.system(size: 18, weight: .medium, design: .rounded)).padding(24)
            Button { Task { await controller.accept() } } label: {
                Text(model.progress.settings.language.text("Accept")).font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(.white).frame(maxWidth: .infinity).frame(height: 52)
                    .background(Capsule().fill(CapyPalette.actionOrange))
            }.buttonStyle(StartupWelcomeButtonStyle())
                .accessibilityIdentifier("accept_terms").padding([.horizontal, .bottom], 24)
        }
        .foregroundColor(CapyPalette.ink).background(CapyPalette.paper)
        .clipShape(RoundedRectangle(cornerRadius: 24)).frame(maxWidth: 310)
        .accessibilityAddTraits(.isModal)
    }
}

private struct StartupWelcomePresentationIdentity: Hashable {
    let active: Bool
    let reduceMotion: Bool
}

/// Keep the Welcome controls' existing geometry while giving their functional
/// text a predictable pressed contrast (Original [303, 306]).
struct StartupWelcomeButtonStyle: ButtonStyle {
    static let pressedOpacity: Double = 0.86

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? Self.pressedOpacity : 1)
    }
}
