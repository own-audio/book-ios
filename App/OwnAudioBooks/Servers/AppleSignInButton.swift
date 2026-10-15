import AuthenticationServices
import SwiftUI

/// Sign in with Apple to the own.audio server whose address is typed above it. Apple's own
/// button: black on a light background, white on a dark one, as Apple asks.
struct AppleSignInButton: View {
    let address: String
    let name: String
    @Binding var isWorking: Bool
    @Binding var errorMessage: String?
    var onSignedIn: () -> Void = {}
    /// Set to sign in to this saved server again rather than add one.
    var replacing: UUID? = nil

    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    // Held for the whole Apple sheet: SignInWithAppleButton's own completion was lost when
    // SwiftUI rebuilt the button while the sheet was up (the keyboard going away is enough),
    // and the sign-in silently went nowhere.
    @State private var apple = AppleSignIn()

    private var hasAddress: Bool { !address.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: Theme.Spacing.xs) {
            SignInWithAppleButton(.signIn) { _ in } onCompletion: { _ in }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .id(colorScheme)
                .frame(height: 50)
                .clipShape(Capsule())
                .allowsHitTesting(false)
                .overlay {
                    // The real tap target: Apple's button only draws.
                    Button { start() } label: { Color.clear.contentShape(Capsule()) }
                        .accessibilityLabel(Text("Sign in with Apple"))
                        .accessibilityIdentifier("addServer.apple")
                }
                .disabled(!hasAddress || isWorking)
                .opacity(hasAddress ? 1 : 0.5)
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(Theme.Colors.error)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("addServer.appleError")
            }
        }
    }

    private func start() {
        errorMessage = nil
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let credential = try await apple.signIn()
                guard let data = credential.identityToken, let token = String(data: data, encoding: .utf8) else {
                    errorMessage = String(localized: "Apple didn't return a sign-in. Try again.")
                    return
                }
                // Apple gives the name only the first time someone signs in to this app.
                let fullName = credential.fullName.map { PersonNameComponentsFormatter.localizedString(from: $0, style: .default) }
                let signIn = AppModel.OwnAudioSignIn.apple(identityToken: token, fullName: fullName)
                if let replacing {
                    try await model.signInAgain(serverId: replacing, with: signIn)
                } else {
                    try await model.addOwnAudioServer(address: address, signIn: signIn, name: name)
                }
                Haptics.impact(.medium)
                onSignedIn()
            } catch let error as ASAuthorizationError where error.code == .canceled {
                return
            } catch where error.isTwoFactorNeeded {
                // The code sheet takes it from here.
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// One Sign in with Apple request at a time, as async/await, kept alive by its owner.
@MainActor
final class AppleSignIn: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>?
    private var controller: ASAuthorizationController?

    func signIn() async throws -> ASAuthorizationAppleIDCredential {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        self.controller = controller
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        MainActor.assumeIsolated {
            if let credential = authorization.credential as? ASAuthorizationAppleIDCredential {
                finish(.success(credential))
            } else {
                finish(.failure(ASAuthorizationError(.unknown)))
            }
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        MainActor.assumeIsolated { finish(.failure(error)) }
    }

    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        }
    }

    private func finish(_ result: Result<ASAuthorizationAppleIDCredential, Error>) {
        continuation?.resume(with: result)
        continuation = nil
        controller = nil
    }
}
