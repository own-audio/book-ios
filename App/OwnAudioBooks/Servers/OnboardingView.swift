import SwiftUI

/// The first screen, over the own.audio hero: the mark, the wordmark, and the one thing the
/// app needs, a server.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var name = ""
    @State private var isConnecting = false
    @State private var isTryingDemo = false
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
                    ServerForm(address: $address, username: $username, password: $password, name: $name, focus: $focus, canConnect: canConnect, connect: connect)
                    CanaryServerButton(address: $address)
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
                    demo
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
    }

    private var header: some View {
        VStack(spacing: Theme.Spacing.md) {
            OwnAudioMark.tribe(size: 72)
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

    /// Someone without a server yet can still see what the app does.
    private var demo: some View {
        VStack(spacing: Theme.Spacing.xs) {
            Divider().padding(.vertical, Theme.Spacing.sm)
            Text("No server yet?")
                .font(.subheadline)
                .foregroundStyle(Theme.Colors.muted)
            Button {
                tryDemo()
            } label: {
                Group {
                    if isTryingDemo { ProgressView() } else { Text("Try the Demo Library") }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(isConnecting || isTryingDemo)
            .accessibilityIdentifier("addServer.demo")
            Text("A shared own.audio server with public-domain books. Remove it in Settings when you add your own.")
                .font(.footnote)
                .foregroundStyle(Theme.Colors.muted)
                .multilineTextAlignment(.center)
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            note("checkmark.shield", "Your sign-in stays in this iPhone's Keychain; both kinds of server hand out tokens, and the password is not kept.")
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
