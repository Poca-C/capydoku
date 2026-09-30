import SwiftUI

@main
struct CapydokuApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model)
                .preferredColorScheme(.light)
                .onChange(of: phase) { model.setActive($0 == .active) }
        }
    }
}
