import SwiftUI

/// A new account on own.audio's hosted service, signed in as a server straight after.
struct SignUpView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @FocusState private var focus: Field?

    private enum Field { case name, email, password }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && email.contains("@") && password.count >= 12 && !isWorking
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Your Name", text: $name)
                        .textContentType(.name)
                        .focused($focus, equals: .name)
                        .submitLabel(.next)
                        .onSubmit { focus = .email }
                        .accessibilityIdentifier("signUp.name")
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .email)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }
                        .accessibilityIdentifier("signUp.email")
                    SecureField("Password", text: $password)
                        .textContentType(.newPassword)
                        .focused($focus, equals: .password)
                        .submitLabel(.go)
                        .onSubmit { if canCreate { create() } }
                        .accessibilityIdentifier("signUp.password")
                } footer: {
                    Text("At least 12 characters. A few words are fine.")
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.Colors.error)
                            .accessibilityIdentifier("signUp.error")
                    }
                }
                Section {
                    Button {
                        create()
                    } label: {
                        HStack { Spacer(); if isWorking { ProgressView() } else { Text("Create Account").bold() }; Spacer() }
                    }
                    .disabled(!canCreate)
                    .accessibilityIdentifier("signUp.create")
                } footer: {
                    Text("own.audio emails you a link to confirm the address. By creating an account you agree to the [Terms](https://www.own.audio/terms/) and the [Privacy Policy](https://www.own.audio/privacy/).")
                }
            }
            .navigationTitle("own.audio Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { focus = .name }
        }
    }

    private func create() {
        guard canCreate else { return }
        focus = nil
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await model.createOwnAudioAccount(name: name, email: email, password: password)
                Haptics.impact(.medium)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}
