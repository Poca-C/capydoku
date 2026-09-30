import SwiftUI

struct StartupFlowView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var controller: StartupController
    @State private var legalTitle: String?

    init(directory: URL) {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let skip = StartupController.shouldSkipForTests(arguments: arguments, environment: ProcessInfo.processInfo.environment)
        #else
        let skip = false
        #endif
        _controller = StateObject(wrappedValue: StartupController(directory: directory, skip: skip))
    }
    var body: some View {
        ZStack {
            if controller.stage == .ready { RootView() }
            else {
                Color(red: 0.98, green: 0.96, blue: 0.93).ignoresSafeArea()
                VStack(spacing: 24) {
                    Spacer()
                    Image("CapyMascot").resizable().scaledToFit().frame(maxWidth: 210, maxHeight: 240)
                    Text("Capydoku").font(.system(size: 44, weight: .black, design: .rounded)).foregroundColor(.brown)
                    Spacer()
                    ProgressView().tint(.orange).accessibilityLabel("Loading Capydoku")
                    Spacer().frame(height: 64)
                }
                if controller.stage == .welcome {
                    Color.black.opacity(0.65).ignoresSafeArea()
                    VStack(spacing: 0) {
                        Text("Welcome").font(.system(size: 26, weight: .bold, design: .rounded))
                            .frame(maxWidth: .infinity).padding(14).background(Color.orange.opacity(0.10))
                        VStack(spacing: 6) {
                            Text("Please read and accept our")
                            Button { legalTitle = "Terms of Service" } label: { Text("Terms of Service").underline() }
                            Text("and")
                            Button { legalTitle = "Privacy Policy" } label: { Text("Privacy Policy").underline() }
                        }.font(.system(size: 18, weight: .medium, design: .rounded)).padding(24)
                        Button { Task { await controller.accept() } } label: {
                            Text("Accept").font(.system(size: 22, weight: .bold, design: .rounded))
                                .foregroundColor(.white).frame(maxWidth: .infinity).frame(height: 52)
                                .background(Capsule().fill(Color.orange))
                        }.accessibilityIdentifier("accept_terms").padding([.horizontal, .bottom], 24)
                    }
                    .foregroundColor(.brown).background(Color(red: 1, green: 0.99, blue: 0.96))
                    .clipShape(RoundedRectangle(cornerRadius: 24)).frame(maxWidth: 310)
                    .accessibilityAddTraits(.isModal)
                }
            }
        }
        .task {
            controller.onAccepted = { model.consentAccepted() }
            controller.onReady = { model.startupReady() }
            await controller.begin()
            if controller.stage == .ready { model.startupReady() } // Explicit UI-test bypass still reaches this gate.
        }
        .sheet(isPresented: Binding(get: { legalTitle != nil }, set: { if !$0 { legalTitle = nil } })) {
            NavigationView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("Internal demo").font(.title2.bold())
                        Text("The publisher has not supplied the final \(legalTitle ?? "legal document") for this internal build.")
                        Text("This build stores game progress on this device. It does not connect to live advertising or analytics services. Accept continues the internal demo only.")
                    }.padding(24)
                }.navigationTitle(legalTitle ?? "").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Close") { legalTitle = nil } } }
            }
        }
        .alert("Unable to save", isPresented: Binding(get: { controller.errorMessage != nil }, set: { if !$0 { controller.errorMessage = nil } })) {
            Button("OK") { controller.errorMessage = nil }
        } message: { Text(controller.errorMessage ?? "") }
    }
}
