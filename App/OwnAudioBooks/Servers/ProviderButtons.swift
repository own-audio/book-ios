import SwiftUI

/// Sign in with Apple and Google for the own.audio server whose address is typed above: the
/// buttons appear once that server says it offers them, and never for an Audiobookshelf
/// address.
struct ProviderButtons: View {
    @Environment(AppModel.self) private var model
    let address: String
    let name: String
    @Binding var isWorking: Bool
    var replacing: UUID? = nil
    var onSignedIn: () -> Void = {}
    @State private var providers: Set<String> = []
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: Theme.Spacing.xs) {
            if providers.contains("apple") {
                AppleSignInButton(address: address, name: name, isWorking: $isWorking, errorMessage: $errorMessage, onSignedIn: onSignedIn, replacing: replacing)
            }
            if providers.contains("google") {
                GoogleSignInButton(address: address, name: name, isWorking: $isWorking, errorMessage: $errorMessage, onSignedIn: onSignedIn, replacing: replacing)
            }
            if !providers.isEmpty {
                Text("With your own.audio account.")
                    .font(.footnote)
                    .foregroundStyle(Theme.Colors.muted)
            }
        }
        .task(id: address) {
            let typed = address.trimmingCharacters(in: .whitespaces)
            guard typed.count >= 4 else { providers = []; return }
            // A pause after typing, so each letter does not ask a server.
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            providers = await model.ownAudioProviders(address: typed)
        }
    }
}
