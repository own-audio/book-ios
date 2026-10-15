import Foundation
import Testing

@testable import PlayerCore

/// The real failure this guards: Navidrome 0.64.0 answered `stream.view` with HTTP 200 and a
/// 182-byte Subsonic error body after its id migration, and a download path that only checked
/// the status wrote that to disk as a track.
@Suite("AudioPayloadCheck")
struct AudioPayloadCheckTests {
    /// A real Navidrome 0.64.0 response.
    private static let subsonicError = Data(#"""
    {"subsonic-response":{"status":"failed","version":"1.16.1","type":"navidrome","serverVersion":"0.64.0 (1072e9f7)","openSubsonic":true,"error":{"code":70,"message":"data not found"}}}
    """#.utf8)

    @Test("the Subsonic error body that got stored 91 times is rejected, 200 or not")
    func rejectsSubsonicErrorBody() {
        #expect(!AudioPayloadCheck.looksLikeAudio(contentType: "application/json", prefix: Self.subsonicError))
        // Servers have been seen labelling it audio; the bytes still decide.
        #expect(!AudioPayloadCheck.looksLikeAudio(contentType: "audio/mpeg", prefix: Self.subsonicError))
        #expect(!AudioPayloadCheck.looksLikeAudio(contentType: nil, prefix: Self.subsonicError))
    }

    @Test("an HTML error page from a proxy is rejected too")
    func rejectsHTML() {
        let html = Data("<!DOCTYPE html><html><body>502 Bad Gateway</body></html>".utf8)
        #expect(!AudioPayloadCheck.looksLikeAudio(contentType: "text/html", prefix: html))
    }

    @Test("real audio headers are accepted, including when the type is unhelpful")
    func acceptsAudio() {
        let mp3WithTag = Data(Array("ID3".utf8) + [0x04, 0x00, 0x00])
        let bareFrame = Data([0xFF, 0xFB, 0x90, 0x44])
        let flac = Data(Array("fLaC".utf8) + [0x00, 0x00])
        let m4a = Data([0x00, 0x00, 0x00, 0x20] + Array("ftypM4A ".utf8))
        for payload in [mp3WithTag, bareFrame, flac, m4a] {
            #expect(AudioPayloadCheck.looksLikeAudio(contentType: "application/octet-stream", prefix: payload))
        }
    }

    @Test("a file too small to be a track is rejected even if its first bytes look right")
    func rejectsTooSmallFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp3")
        try Data(Array("ID3".utf8) + Array(repeating: UInt8(0), count: 100)).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(!AudioPayloadCheck.looksLikeAudio(contentType: "audio/mpeg", fileURL: url))
    }

    @Test("a real-sized file with an audio header is accepted from disk")
    func acceptsPlausibleFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp3")
        try Data(Array("ID3".utf8) + Array(repeating: UInt8(0), count: 4096)).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(AudioPayloadCheck.looksLikeAudio(contentType: "audio/mpeg", fileURL: url))
    }
}
