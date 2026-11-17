import Foundation
import OwnAudioKit

/// Why an own.audio server turned down a new account.
public enum SignUpError: Error, Sendable, Equatable {
    case invalidEmail, weakPassword, missingName, closed, emailTaken
    /// Another reason, in the server's words when it gave any.
    case refused(String?)
}

/// A new account with a password on an own.audio server; the app signs in to it afterwards.
public enum OwnAudioSignUp {
    /// Throws `SignUpError`, or `SourceError.network` when the server can't be reached.
    public static func register(host: URL, email: String, password: String, displayName: String, urlSession: URLSession) async throws {
        do {
            try await OwnAudioClient.register(host: host, email: email, password: password, displayName: displayName, session: urlSession)
        } catch OwnAudioError.problem(let p) {
            throw switch p.code {
            case "invalid_email": SignUpError.invalidEmail
            case "weak_password": SignUpError.weakPassword
            case "invalid_display_name": SignUpError.missingName
            case "registration_closed": SignUpError.closed
            case "email_taken": SignUpError.emailTaken
            default: SignUpError.refused(p.detail)
            }
        } catch OwnAudioError.network, OwnAudioError.offline {
            throw SourceError.network
        } catch {
            throw SignUpError.refused(nil)
        }
    }
}
