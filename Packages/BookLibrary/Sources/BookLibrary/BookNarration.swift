import Foundation
import OwnAudioKit

// Narration: an ebook read by an AI voice into an audiobook, on hosted own.audio servers that
// advertise the `narration` module. The app sees the kit's types through these names.

public typealias NarrationLanguage = OwnAudioKit.NarrationLanguage
public typealias NarrationVoice = OwnAudioKit.NarrationVoice
public typealias NarrationQuote = OwnAudioKit.NarrationQuote
public typealias NarrationJob = OwnAudioKit.NarrationJob
public typealias NarrationOutput = OwnAudioKit.NarrationOutput

/// The server's languages and voices, fetched together.
public struct NarrationOptions: Sendable, Equatable {
    public let languages: [NarrationLanguage]
    public let voices: [NarrationVoice]

    /// Only a language with a voice can be read aloud; the source can be any of them.
    public var targetLanguages: [NarrationLanguage] {
        let voiced = Set(voices.map(\.language))
        return languages.filter { voiced.contains($0.code) }
    }

    public func voices(for language: String) -> [NarrationVoice] {
        voices.filter { $0.language == language }
    }
}

public protocol BookNarrator: BookSource {
    func narrationOptions() async throws -> NarrationOptions
    /// The server's count of characters in the file; nothing is charged.
    func narrationCharacterCount(fileURL: URL) async throws -> Int
    func narrationQuote(charCount: Int, sourceLanguage: String, targetLanguage: String, voiceId: String) async throws -> NarrationQuote
    func startNarration(fileURL: URL, title: String, sourceLanguage: String, targetLanguage: String, voiceId: String, output: NarrationOutput) async throws -> NarrationJob
    func narration(id: String) async throws -> NarrationJob
}

extension OwnAudioSource: BookNarrator {
    public func narrationOptions() async throws -> NarrationOptions {
        try await translating {
            async let languages = client.narrationLanguages()
            let voices = try await client.narrationVoices()
            return NarrationOptions(languages: try await languages, voices: voices)
        }
    }

    public func narrationCharacterCount(fileURL: URL) async throws -> Int {
        try await translating { try await client.narrationEstimate(fileURL: fileURL).estimatedCharCount }
    }

    public func narrationQuote(charCount: Int, sourceLanguage: String, targetLanguage: String, voiceId: String) async throws -> NarrationQuote {
        try await translating { try await client.narrationQuote(charCount: charCount, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage, voiceId: voiceId) }
    }

    public func startNarration(fileURL: URL, title: String, sourceLanguage: String, targetLanguage: String, voiceId: String, output: NarrationOutput) async throws -> NarrationJob {
        try await translating {
            try await client.createNarration(fileURL: fileURL, title: title, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage, voiceId: voiceId, output: output)
        }
    }

    public func narration(id: String) async throws -> NarrationJob {
        try await translating { try await client.narration(id: id) }
    }
}
