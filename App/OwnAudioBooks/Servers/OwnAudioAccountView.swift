import SwiftUI

/// own.audio's hosted service in one sheet, for creating an account or signing in to one: Apple
/// and Google first (they also make the account on first use), then email and password. The
/// address is fixed, so nothing else is asked.
struct OwnAudioAccountView: View {
    enum Mode { case signUp, signIn }

    let mode: Mode
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var providerError: String?
    @State private var providers: Set<String> = []
    @FocusState private var focus: Field?

    private enum Field { case name, email, password }

    private var canSubmit: Bool {
        guard email.contains("@"), !isWorking else { return false }
        switch mode {
        case .signUp: return !name.trimmingCharacters(in: .whitespaces).isEmpty && password.count >= 12
        case .signIn: return !password.isEmpty
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if providers.contains("apple") || providers.contains("google") {
                    Section {
                        if providers.contains("apple") { AppleSignInButton(address: AppModel.ownAudioService.absoluteString, name: "", isWorking: $isWorking, errorMessage: $providerError, onSignedIn: { dismiss() }) }
                        if providers.contains("google") { GoogleSignInButton(address: AppModel.ownAudioService.absoluteString, name: "", isWorking: $isWorking, errorMessage: $providerError, onSignedIn: { dismiss() }) }
                    } footer: {
                        Text(mode == .signUp ? "Or create an account with your email." : "Or sign in with your email.")
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }
                Section {
                    // The address is never typed here: both modes are for own.audio's hosted service.
                    LabeledContent {
                        Text(verbatim: "own.audio")
                    } label: {
                        Label("Server", systemImage: "globe")
                    }
                    .accessibilityIdentifier("account.server")
                    if mode == .signUp {
                        TextField("Your Name", text: $name)
                            .textContentType(.name)
                            .focused($focus, equals: .name)
                            .submitLabel(.next)
                            .onSubmit { focus = .email }
                            .accessibilityIdentifier("account.name")
                    }
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .email)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }
                        .accessibilityIdentifier("account.email")
                    SecureField("Password", text: $password)
                        .textContentType(mode == .signUp ? .newPassword : .password)
                        .focused($focus, equals: .password)
                        .submitLabel(.go)
                        .onSubmit { if canSubmit { submit() } }
                        .accessibilityIdentifier("account.password")
                } footer: {
                    if mode == .signUp { Text("At least 12 characters. A few words are fine.") }
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.Colors.error)
                            .accessibilityIdentifier("account.error")
                    }
                }
                Section {
                    Button {
                        submit()
                    } label: {
                        HStack {
                            Spacer()
                            if isWorking { ProgressView() } else { Text(mode == .signUp ? "Create Account" : "Sign In").bold() }
                            Spacer()
                        }
                    }
                    .disabled(!canSubmit)
                    .accessibilityIdentifier("account.submit")
                } footer: {
                    if mode == .signUp {
                        Text("own.audio emails you a link to confirm the address. By creating an account you agree to the [Terms](https://www.own.audio/terms/) and the [Privacy Policy](https://www.own.audio/privacy/).")
                    }
                }
            }
            .navigationTitle(mode == .signUp ? "own.audio Account" : "Sign In to own.audio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { providers = await model.ownAudioProviders(address: AppModel.ownAudioService.absoluteString) }
            .sheet(item: model.pendingTwoFactorBinding) { _ in TwoFactorView() }
        }
    }

    private func submit() {
        guard canSubmit else { return }
        focus = nil
        isWorking = true
        errorMessage = nil
        let email = email.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                switch mode {
                case .signUp:
                    try await model.createOwnAudioAccount(name: name, email: email, password: password)
                case .signIn:
                    try await model.addServer(address: AppModel.ownAudioService.absoluteString, username: email, password: password, name: "")
                }
                Haptics.impact(.medium)
                dismiss()
            } catch where error.isTwoFactorNeeded {
                // The code is asked for next.
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}

extension OwnAudioAccountView.Mode: Identifiable {
    var id: Self { self }
}
