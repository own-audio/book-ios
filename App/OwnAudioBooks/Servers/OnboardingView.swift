import SwiftUI

/// The first screen, over the own.audio hero: the mark, the wordmark, an own.audio account for
/// someone without a server, and the server form.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var name = ""
    @State private var isConnecting = false
    @State private var isTryingDemo = false
    @State private var account: OwnAudioAccountView.Mode?
    @State private var errorMessage: String?
    @FocusState private var focus: OnboardingField?

    private var canConnect: Bool {
        !address.trimmingCharacters(in: .whitespaces).isEmpty && !username.isEmpty && !password.isEmpty && !isConnecting
    }

    var body: some View {
        ZStack {
            HeroBackground()
            ScrollView {
                VStack(spacing: Theme.Spacing.xl) {
                    header
                    ownAudioAccount
                    Text("Or connect your own server")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.Colors.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, -Theme.Spacing.md)
                    ServerForm(address: $address, username: $username, password: $password, name: $name, focus: $focus, canConnect: canConnect, connect: connect)
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(Theme.Colors.error)
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
                    ProviderButtons(address: address, name: name, isWorking: $isConnecting)
                    notes
                    Link(destination: URL(string: "https://github.com/own-audio/book-ios")!) {
                        Text("Free and open source · MPL-2.0").font(.footnote)
                    }
                    .padding(.top, Theme.Spacing.sm)
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.vertical, Theme.Spacing.xxl)
                .frame(maxWidth: 420)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .sheet(item: model.pendingTwoFactorBinding) { _ in TwoFactorView() }
        .sheet(item: $account) { OwnAudioAccountView(mode: $0) }
    }

    private var header: some View {
        VStack(spacing: Theme.Spacing.md) {
            OwnAudioMark.tribe(size: 120)
            RotatingWordmark()
            Text("Your audiobooks, from your own server.")
                .font(.subheadline)
                .foregroundStyle(Theme.Colors.muted)
                .multilineTextAlignment(.center)
            Text(verbatim: "own.audio · Audiobookshelf")
                .font(.footnote)
                .foregroundStyle(Theme.Colors.muted)
        }
        .padding(.bottom, Theme.Spacing.sm)
    }

    /// own.audio's hosted service first: an account there is a server, with nothing to run.
    private var ownAudioAccount: some View {
        VStack(spacing: Theme.Spacing.md) {
            VStack(spacing: Theme.Spacing.xs) {
                Text("No server? Use own.audio")
                    .font(.headline)
                Text("own.audio keeps your audiobooks for you. Upload them once and listen here.")
                    .font(.footnote)
                    .foregroundStyle(Theme.Colors.muted)
                    .multilineTextAlignment(.center)
            }
            Button {
                account = .signUp
            } label: {
                Text("Create an own.audio Account").bold().frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("addServer.signUp")
            Button {
                account = .signIn
            } label: {
                Text("Sign In").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityIdentifier("addServer.ownAudioSignIn")
            // Someone not ready for an account can still see what the app does.
            Button {
                tryDemo()
            } label: {
                if isTryingDemo { ProgressView() } else { Text("Try the Demo Library") }
            }
            .font(.subheadline.weight(.semibold))
            .disabled(isConnecting || isTryingDemo)
            .accessibilityIdentifier("addServer.demo")
            Text("Public-domain books on a shared own.audio server, no account needed.")
                .font(.footnote)
                .foregroundStyle(Theme.Colors.muted)
                .multilineTextAlignment(.center)
                .padding(.top, -Theme.Spacing.sm)
        }
        .padding(Theme.Spacing.lg)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.miniPlayer, style: .continuous))
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            note("checkmark.shield", "Your sign-in stays in this device's Keychain; both kinds of server hand out tokens, and the password is not kept.")
            note("info.circle", "own.audio: your account's email and password. Audiobookshelf: your user name and password.")
            note("network", "Without http:// or https://, the app tries https and then http, so a server at home works as typed.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func note(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        Label {
            Text(text).font(.footnote).foregroundStyle(Theme.Colors.muted)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Theme.Colors.muted).font(.footnote)
        }
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
            } catch where error.isTwoFactorNeeded {
                // The code sheet takes it from here.
            } catch {
                errorMessage = error.localizedDescription
            }
            isConnecting = false
        }
    }

    private func tryDemo() {
        focus = nil
        isTryingDemo = true
        errorMessage = nil
        Task {
            do {
                try await model.addDemoServer()
                Haptics.impact(.medium)
            } catch {
                errorMessage = error.localizedDescription
            }
            isTryingDemo = false
        }
    }
}

/// Address, user, password, name — the same four fields on the first screen and in Settings,
/// on material so they read over the hero.
struct ServerForm: View {
    @Binding var address: String
    @Binding var username: String
    @Binding var password: String
    @Binding var name: String
    var focus: FocusState<OnboardingField?>.Binding
    let canConnect: Bool
    let connect: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            row("globe") {
                TextField("Server address", text: $address, prompt: Text(verbatim: "books.example.com"))
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused(focus, equals: .address)
                    .submitLabel(.next)
                    .onSubmit { focus.wrappedValue = .username }
                    .accessibilityIdentifier("addServer.address")
            }
            Divider().padding(.leading, 48)
            row("person") {
                TextField("User name or email", text: $username)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused(focus, equals: .username)
                    .submitLabel(.next)
                    .onSubmit { focus.wrappedValue = .password }
                    .accessibilityIdentifier("addServer.username")
            }
            Divider().padding(.leading, 48)
            row("key") {
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused(focus, equals: .password)
                    .submitLabel(.go)
                    .onSubmit { if canConnect { connect() } }
                    .accessibilityIdentifier("addServer.password")
            }
            Divider().padding(.leading, 48)
            row("tag") {
                TextField("Name (optional)", text: $name)
                    .focused(focus, equals: .name)
                    .accessibilityIdentifier("addServer.name")
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.miniPlayer, style: .continuous))
    }

    private func row<Field: View>(_ symbol: String, @ViewBuilder field: () -> Field) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: symbol)
                .foregroundStyle(Theme.Colors.muted)
                .frame(width: 24)
                .accessibilityHidden(true)
            field()
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .frame(minHeight: 52)
    }
}

enum OnboardingField { case address, username, password, name }

extension AppModel {
    var pendingTwoFactorBinding: Binding<PendingTwoFactor?> {
        Binding(get: { self.pendingTwoFactor }, set: { if $0 == nil { self.cancelTwoFactor() } })
    }
}

/// The second step of an own.audio sign-in with two-factor on: the authenticator's code.
struct TwoFactorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var onDone: (() -> Void)? = nil
    @State private var code = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Code", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .focused($focused)
                        .accessibilityIdentifier("twoFactor.code")
                } footer: {
                    Text("The six-digit code from your authenticator app, or one of your recovery codes.")
                }
                if let errorMessage {
                    Section { Label(errorMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.Colors.error) }
                }
                Section {
                    Button {
                        submit()
                    } label: {
                        HStack { Spacer(); if isWorking { ProgressView() } else { Text("Sign In").bold() }; Spacer() }
                    }
                    .disabled(code.trimmingCharacters(in: .whitespaces).count < 6 || isWorking)
                    .accessibilityIdentifier("twoFactor.submit")
                }
            }
            .navigationTitle("Two-Factor Sign-In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.cancelTwoFactor(); dismiss() }
                }
            }
            .onAppear { focused = true }
        }
    }

    private func submit() {
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await model.finishTwoFactor(code: code.trimmingCharacters(in: .whitespaces))
                Haptics.impact(.medium)
                onDone?()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}
