import AudiobookshelfKit
import Foundation
import OwnAudioKit

/// Adding a server: what has to happen before there is a `ServerRecord` to make a source from.
public enum ServerSetup {
    // MARK: - Audiobookshelf

    public struct AudiobookshelfSignIn: Sendable {
        public var record: ServerRecord
        /// The account's book libraries; the record's `libraryId` is the default one, and the
        /// app lets the listener pick another when there are several.
        public let libraries: [(id: String, name: String)]
        public let serverVersion: String
    }

    /// Checks that an Audiobookshelf server is at `host`, signs in, and finds its book
    /// libraries. Throws `.signInRejected` for a wrong password, `.unreadable` when the
    /// address is not an Audiobookshelf server, `.unsupported` when the account reaches no
    /// book library.
    public static func audiobookshelfSignIn(host: URL, username: String, password: String, urlSession: URLSession) async throws -> AudiobookshelfSignIn {
        let status: ServerStatus
        do {
            status = try await AudiobookshelfClient.status(host: host, session: urlSession)
        } catch AudiobookshelfError.network {
            throw SourceError.network
        } catch {
            throw SourceError.unreadable
        }
        let signIn: SignIn
        do {
            signIn = try await AudiobookshelfClient.signIn(host: host, username: username, password: password, session: urlSession)
        } catch let error as AudiobookshelfError {
            throw AudiobookshelfSource.sourceError(error)
        }
        let client = AudiobookshelfClient(host: host, tokens: AudiobookshelfKit.TokenSession(signIn.tokens), session: urlSession)
        let libraries: [Library]
        do {
            libraries = try await client.bookLibraries()
        } catch let error as AudiobookshelfError {
            throw AudiobookshelfSource.sourceError(error)
        }
        guard !libraries.isEmpty else { throw SourceError.unsupported }
        let library = libraries.first { $0.id == signIn.defaultLibraryId } ?? libraries[0]
        let record = ServerRecord(
            displayName: host.host() ?? "Audiobookshelf", kind: .audiobookshelf, host: host,
            auth: .audiobookshelf(username: signIn.user.username, tokens: signIn.tokens),
            libraryId: library.id, userId: signIn.user.id
        )
        return AudiobookshelfSignIn(record: record, libraries: libraries.map { ($0.id, $0.name) }, serverVersion: status.serverVersion)
    }

    // MARK: - own.audio

    public enum OwnAudioSignInResult: Sendable {
        case signedIn(ServerRecord)
        /// The account asks for a second factor: finish with `ownAudioFinishTwoFactor`.
        case twoFactor(mfaToken: String, methods: [String])
    }

    /// The hosted service's API for the addresses people know from the browser: the web app
    /// and the site serve pages, not the API, so they would never answer as a server. Anything
    /// else is returned as typed.
    public static func ownAudioAPIAddress(_ address: String) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let bare = trimmed.lowercased()
            .replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch bare {
        case "own.audio", "www.own.audio", "app.own.audio": return "https://api.own.audio"
        case "app-canary.own.audio": return "https://api-canary.own.audio"
        default: return trimmed
        }
    }

    /// Email and password through the token endpoint.
    public static func ownAudioSignIn(host: URL, email: String, password: String, device: DeviceIdentity, urlSession: URLSession) async throws -> OwnAudioSignInResult {
        try await ownAudioRecord(host: host, urlSession: urlSession) {
            try await OwnAudioClient.signIn(host: host, email: email, password: password, device: device.ownAudio, session: urlSession)
        }
    }

    /// A provider's id token (`apple`, `google`); `fullName` on the first Apple sign-in only.
    public static func ownAudioSignIn(host: URL, provider: String, idToken: String, fullName: String?, device: DeviceIdentity, urlSession: URLSession) async throws -> OwnAudioSignInResult {
        try await ownAudioRecord(host: host, urlSession: urlSession) {
            try await OwnAudioClient.signIn(host: host, provider: provider, idToken: idToken, fullName: fullName, device: device.ownAudio, session: urlSession)
        }
    }

    public static func ownAudioFinishTwoFactor(host: URL, mfaToken: String, code: String, urlSession: URLSession) async throws -> ServerRecord {
        let result = try await ownAudioRecord(host: host, urlSession: urlSession) {
            try await OwnAudioClient.finishTwoFactor(host: host, mfaToken: mfaToken, code: code, session: urlSession)
        }
        guard case .signedIn(let record) = result else { throw SourceError.signInRejected }
        return record
    }

    private static func ownAudioRecord(host: URL, urlSession: URLSession, signIn: () async throws -> OwnAudioKit.Tokens) async throws -> OwnAudioSignInResult {
        let tokens: OwnAudioKit.Tokens
        do {
            tokens = try await signIn()
        } catch OwnAudioError.twoFactorRequired(let mfaToken, let methods) {
            return .twoFactor(mfaToken: mfaToken, methods: methods)
        } catch let error as OwnAudioError {
            throw OwnAudioSource.sourceError(error)
        }
        let client = OwnAudioClient(host: host, tokens: OwnAudioKit.TokenSession(tokens), session: urlSession)
        let me: OwnAudioClient.Me
        do {
            me = try await client.me()
        } catch let error as OwnAudioError {
            throw OwnAudioSource.sourceError(error)
        }
        let info = try? await ownAudioInfo(at: host, urlSession: urlSession)
        var record = ServerRecord(
            displayName: info?.name ?? host.host() ?? "own.audio", kind: .ownAudio, host: host,
            auth: .ownAudio(username: me.email, tokens: tokens), userId: me.id, serverId: info?.id
        )
        record.learn(info?.addresses ?? [])
        return .signedIn(record)
    }

    /// The account a public demo server offers to strangers (`demo` in its v1 server document).
    public static func ownAudioDemoAccount(host: URL, urlSession: URLSession) async throws -> (email: String, password: String) {
        struct Body: Decodable {
            struct Demo: Decodable { let email: String; let password: String }
            let demo: Demo?
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(from: host.appending(path: "api/v1/server"))
        } catch {
            throw SourceError.network
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let demo = try? JSONDecoder().decode(Body.self, from: data).demo
        else { throw SourceError.unreadable }
        return (demo.email, demo.password)
    }
}
