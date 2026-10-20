import BookLibrary
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var removingServer: ServerRecord?
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            ServersSection(removing: $removingServer)

            Section {
                NavigationLink {
                    DownloadsView()
                } label: {
                    LabeledContent("Downloads", value: ByteCountFormatter.string(fromByteCount: model.downloads.totalBytes, countStyle: .file))
                }
                .accessibilityIdentifier("settings.downloads")
                Toggle("Offline Mode", isOn: Binding(get: { model.settings.offlineMode }, set: { model.setOfflineMode($0) }))
                    .accessibilityIdentifier("settings.offlineMode")
                Toggle("Download on Wi-Fi Only", isOn: $settings.wifiOnlyDownloads)
                    .accessibilityIdentifier("settings.wifiOnly")
                Picker("Keep at Most", selection: $settings.storageCapBytes) {
                    ForEach(PlaybackSettings.storageCapChoices, id: \.self) { cap in
                        Text(cap.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? String(localized: "No Limit")).tag(cap)
                    }
                }
                .accessibilityIdentifier("settings.storageCap")
                if model.servers.contains(where: { $0.kind == .ownAudio }) {
                    Toggle("Whole Library When Offline", isOn: $settings.wholeLibraryOffline)
                        .accessibilityIdentifier("settings.wholeLibrary")
                }
            } footer: {
                Text("Offline Mode shows and plays only what is on this iPhone, as the app does on its own with no network. Over the limit, finished books go first, then the ones not played for longest; never the one playing.\n\nWith Whole Library, an own.audio server's whole library is listed offline from the copy on this iPhone, with the books not downloaded greyed out; only downloaded books play.")
            }
            .onChange(of: settings.wifiOnlyDownloads) { model.applyPlaybackSettings() }
            .onChange(of: settings.storageCapBytes) { model.applyPlaybackSettings() }

            Section("Playback") {
                // Back before forward, as the buttons sit in the player.
                Picker("Skip Back", selection: $settings.skipBackwardSecs) {
                    ForEach(PlaybackSettings.skipChoices, id: \.self) { Text("\(Int($0)) s").tag($0) }
                }
                .accessibilityIdentifier("settings.skipBackward")
                Picker("Skip Forward", selection: $settings.skipForwardSecs) {
                    ForEach(PlaybackSettings.skipChoices, id: \.self) { Text("\(Int($0)) s").tag($0) }
                }
                .accessibilityIdentifier("settings.skipForward")
                Picker("Speed for New Books", selection: $settings.defaultRate) {
                    ForEach([0.75, 1.0, 1.25, 1.5, 1.75, 2.0] as [Float], id: \.self) { Text(String(format: "%.2g×", $0)).tag($0) }
                }
                Toggle("Smart Rewind", isOn: $settings.smartRewind)
                    .accessibilityIdentifier("settings.smartRewind")
            }
            .onChange(of: settings.skipForwardSecs) { model.applyPlaybackSettings() }
            .onChange(of: settings.skipBackwardSecs) { model.applyPlaybackSettings() }
            .onChange(of: settings.smartRewind) { model.applyPlaybackSettings() }

            Section {
                Picker("On Mobile Data", selection: $settings.mobileData) {
                    Text("Original").tag(PlaybackSettings.MobileData.original)
                    Text("Saver").tag(PlaybackSettings.MobileData.saver)
                    Text("Downloaded Only").tag(PlaybackSettings.MobileData.downloadedOnly)
                }
                .accessibilityIdentifier("settings.mobileData")
            } header: {
                Text("Streaming")
            } footer: {
                Text("Saver asks the server for a smaller stream where it makes one (\(PlaybackSettings.saverBitrateKbps) kbps is plenty for speech). Downloaded Only plays nothing that is not on this iPhone.")
            }

            Section {
                LabeledContent("Version", value: version)
                Link("Source Code and Licence", destination: URL(string: "https://github.com/own-audio/book-ios")!)
                Link("Privacy", destination: URL(string: "https://github.com/own-audio/book-ios/blob/main/PRIVACY.md")!)
                // Tinted like the links above it.
                NavigationLink { LogsView() } label: { Text("Logs").foregroundStyle(.tint) }
                    .accessibilityIdentifier("settings.logs")
            } header: {
                Text("About")
            } footer: {
                Text("own.audio Books is free and open source (MPL-2.0). It talks only to the servers you add.")
            }
        }
        .confirmationDialog(
            "Remove \(removingServer?.displayName ?? "")?",
            isPresented: Binding(get: { removingServer != nil }, set: { if !$0 { removingServer = nil } }),
            titleVisibility: .visible, presenting: removingServer
        ) { server in
            Button("Remove", role: .destructive) { model.perform { try await model.removeServer(id: server.id) } }
        } message: { _ in
            Text("Its downloads leave this iPhone. Nothing changes on the server.")
        }
        .navigationTitle("Settings")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}
