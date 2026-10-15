import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                NavigationLink {
                    ServersView()
                } label: {
                    LabeledContent("Servers", value: model.activeServer?.displayName ?? "")
                }
                .accessibilityIdentifier("settings.servers")
            }

            Section("Playback") {
                Picker("Skip Forward", selection: $settings.skipForwardSecs) {
                    ForEach(PlaybackSettings.skipChoices, id: \.self) { Text("\(Int($0)) s").tag($0) }
                }
                .accessibilityIdentifier("settings.skipForward")
                Picker("Skip Back", selection: $settings.skipBackwardSecs) {
                    ForEach(PlaybackSettings.skipChoices, id: \.self) { Text("\(Int($0)) s").tag($0) }
                }
                .accessibilityIdentifier("settings.skipBackward")
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
            } footer: {
                Text("Saver asks the server for a smaller stream where it makes one (\(PlaybackSettings.saverBitrateKbps) kbps is plenty for speech). Downloaded Only plays nothing that is not on this iPhone.")
            }

            Section {
                LabeledContent("Version", value: version)
                Link("Source Code and Licence", destination: URL(string: "https://github.com/own-audio/book-ios")!)
                Link("Privacy", destination: URL(string: "https://github.com/own-audio/book-ios/blob/main/PRIVACY.md")!)
            } header: {
                Text("About")
            } footer: {
                Text("own.audio Books is free and open source (MPL-2.0). It talks only to the servers you add.")
            }
        }
        .navigationTitle("Settings")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}
