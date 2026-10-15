import SwiftUI

/// Background downloads: iOS relaunches the app to report on them, and hands over a completion
/// handler to call once the session has delivered its events.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == DownloadManager.sessionIdentifier else { return completionHandler() }
        Task { @MainActor in
            AppModel.shared.downloads.backgroundCompletion = completionHandler
            AppModel.shared.downloads.resume()
        }
    }
}

@main
struct OwnAudioBooksApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
