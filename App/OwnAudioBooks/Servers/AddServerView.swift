import SwiftUI

/// Another server, from Settings; the first run has `OnboardingView`.
struct AddServerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var name = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @FocusState private var focus: OnboardingField?

    private var canConnect: Bool {
        !address.trimmingCharacters(in: .whitespaces).isEmpty && !username.isEmpty && !password.isEmpty && !isConnecting
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.xl) {
                ServerForm(address: $address, username: $username, password: $password, name: $name, focus: $focus, canConnect: canConnect, connect: connect)
                CanaryServerButton(address: $address)
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("addServer.error")
                }
                Button {
                    connect()
                } label: {
                    Group {
                        if isConnecting { ProgressView().tint(.white) } else { Text("Connect").bold() }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canConnect)
                .accessibilityIdentifier("addServer.connect")
                Text("Works with own.audio and Audiobookshelf; the app finds out which. Your sign-in stays in this phone's Keychain.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(Theme.Spacing.xl)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Add Server")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        }
        .onAppear { if address.isEmpty { focus = .address } }
        .sheet(item: model.pendingTwoFactorBinding) { _ in TwoFactorView { dismiss() } }
    }

    private func connect() {
        guard canConnect else { return }
        focus = nil
        isConnecting = true
        errorMessage = nil
        Task {
            do {
                try await model.addServer(address: address, username: username, password: password, name: name)
                Haptics.impact(.medium)
                dismiss()
            } catch where error.isTwoFactorNeeded {
            } catch {
                errorMessage = error.localizedDescription
            }
            isConnecting = false
        }
    }
}
