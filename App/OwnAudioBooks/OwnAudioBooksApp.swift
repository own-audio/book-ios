import SwiftUI

@main
struct OwnAudioBooksApp: App {
    @State private var model = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { if !model.hasLoaded { await model.load() } }
        }
        .onChange(of: scenePhase) { _, phase in
            // Audio keeps playing in the background, so this is a save, not a pause.
            if phase == .background { model.engine.saveForTeardown() }
            model.sceneBecame(active: phase != .background)
        }
    }
}
