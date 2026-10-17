import BookLibrary
import SwiftUI
import UniformTypeIdentifiers

/// An ebook read aloud by the server: pick the file, the languages and a voice, see the
/// server's own count and price against the family's credit, then start the job. The job
/// runs on the server for minutes to hours; its row in the Library follows it, and the book
/// arrives through the normal sync.
struct NarrateBookView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let serverId: UUID

    @State private var options: NarrationOptions?
    @State private var fileURL: URL?
    @State private var title = ""
    @State private var sourceLanguage = "en"
    @State private var targetLanguage = "en"
    @State private var voiceId: String?
    @State private var output: NarrationOutput = .multiFile
    @State private var charCount: Int?
    @State private var quote: NarrationQuote?
    @State private var credit: HouseholdCredit?
    @State private var isPicking = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var narrator: (any BookNarrator)? { model.source(for: serverId) as? any BookNarrator }
    private var voices: [NarrationVoice] { options?.voices(for: targetLanguage) ?? [] }
    private var canPrice: Bool { fileURL != nil && voiceId != nil && !isWorking }
    private var canStart: Bool { quote != nil && canPrice && !title.trimmingCharacters(in: .whitespaces).isEmpty && !(credit?.isDepleted ?? false) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { isPicking = true } label: {
                        Label(fileURL.map { $0.lastPathComponent } ?? String(localized: "Choose an Ebook"), systemImage: "doc.badge.plus").lineLimit(1)
                    }
                    .accessibilityIdentifier("narrate.pick")
                    TextField("Title", text: $title).accessibilityIdentifier("narrate.title")
                } header: {
                    Text("Book")
                } footer: {
                    Text("EPUB, MOBI or plain text. The file goes to the server, which reads it aloud; it is not kept afterwards.")
                }

                Section("Voice") {
                    if let options {
                        Picker("Written in", selection: $sourceLanguage) {
                            ForEach(options.languages) { Text($0.label).tag($0.code) }
                        }
                        Picker("Read in", selection: $targetLanguage) {
                            ForEach(options.targetLanguages) { Text($0.label).tag($0.code) }
                        }
                        .accessibilityIdentifier("narrate.targetLanguage")
                        .onChange(of: targetLanguage) { _, _ in
                            if !voices.contains(where: { $0.id == voiceId }) { voiceId = voices.first?.id }
                            quote = nil
                        }
                        Picker("Voice", selection: $voiceId) {
                            ForEach(voices) { voice in Text("\(voice.displayName) · \(voice.gender == "female" ? String(localized: "female") : String(localized: "male"))").tag(Optional(voice.id)) }
                        }
                        .accessibilityIdentifier("narrate.voice")
                        .onChange(of: voiceId) { _, _ in quote = nil }
                        Picker("Files", selection: $output) {
                            Text("One per chapter").tag(NarrationOutput.multiFile)
                            Text("One for the whole book").tag(NarrationOutput.singleM4B)
                        }
                    } else {
                        HStack { Text("Loading voices…"); Spacer(); ProgressView() }
                    }
                }

                Section {
                    if let quote {
                        LabeledContent("Characters", value: quote.charCount.formatted())
                        if quote.translationCostCents > 0 {
                            LabeledContent("Translation", value: Self.price(quote.translationCostCents, quote.currency))
                        }
                        LabeledContent("Price") {
                            Text(Self.price(quote.quotedPriceCents, quote.currency)).bold().accessibilityIdentifier("narrate.price")
                        }
                        if let credit {
                            LabeledContent("Family Credit") {
                                Text(credit.balance, format: .currency(code: credit.currency))
                                    .foregroundStyle(credit.isDepleted ? AnyShapeStyle(Theme.Colors.error) : AnyShapeStyle(.primary))
                            }
                        }
                    } else {
                        Button {
                            Task { await price() }
                        } label: {
                            HStack {
                                Text(charCount == nil ? "Get the Price" : "Price This Voice")
                                if isWorking { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(!canPrice)
                        .accessibilityIdentifier("narrate.price.get")
                    }
                } header: {
                    Text("Price")
                } footer: {
                    Text(sourceLanguage == targetLanguage
                         ? "The server counts the characters it will read and quotes the price; nothing is charged until you start."
                         : "Read in another language than it is written in, the book is translated first; the quote includes that.")
                }

                if let errorMessage {
                    Section { Label(errorMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.Colors.error) }
                }

                Section {
                    Button {
                        Task { await start() }
                    } label: {
                        HStack { Spacer(); Text(quote.map { "Narrate for \(Self.price($0.quotedPriceCents, $0.currency))" } ?? "Narrate").bold(); Spacer() }
                    }
                    .disabled(!canStart)
                    .accessibilityIdentifier("narrate.start")
                } footer: {
                    Text("The price is taken from the family's credit when the book is done. A narration takes minutes to hours; the Library shows how far it is, and the book appears there at the end.")
                }
            }
            .navigationTitle("Narrate an Ebook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .sheet(isPresented: $isPicking) {
                DocumentPicker(types: [.epub, .plainText, UTType(filenameExtension: "mobi") ?? .data]) { urls in
                    guard let picked = urls.first else { return }
                    Task { await take(picked) }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        guard let narrator else { return }
        do {
            let loaded = try await narrator.narrationOptions()
            options = loaded
            if !loaded.targetLanguages.contains(where: { $0.code == targetLanguage }) { targetLanguage = loaded.targetLanguages.first?.code ?? targetLanguage }
            if !loaded.languages.contains(where: { $0.code == sourceLanguage }) { sourceLanguage = loaded.languages.first?.code ?? sourceLanguage }
            if voiceId == nil { voiceId = loaded.voices(for: targetLanguage).first?.id }
        } catch {
            errorMessage = (error as? SourceError)?.userMessage ?? error.localizedDescription
        }
        credit = try? await model.household?.credit()
    }

    /// The picker's access ends with its sheet: a copy in the app's own folder keeps the file.
    private func take(_ picked: URL) async {
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("narrate-\(UUID().uuidString)-\(picked.lastPathComponent)")
        do {
            try FileManager.default.copyItem(at: picked, to: copy)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        if let old = fileURL { try? FileManager.default.removeItem(at: old) }
        fileURL = copy
        charCount = nil
        quote = nil
        errorMessage = nil
        if title.trimmingCharacters(in: .whitespaces).isEmpty { title = picked.deletingPathExtension().lastPathComponent }
    }

    /// The server's count once per file; the quote again for every voice.
    private func price() async {
        guard let narrator, let fileURL, let voiceId else { return }
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        do {
            let count: Int
            if let charCount { count = charCount } else { count = try await narrator.narrationCharacterCount(fileURL: fileURL); charCount = count }
            quote = try await narrator.narrationQuote(charCount: count, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage, voiceId: voiceId)
        } catch {
            errorMessage = (error as? SourceError)?.userMessage ?? error.localizedDescription
        }
    }

    private func start() async {
        guard let narrator, let fileURL, let voiceId else { return }
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        do {
            let job = try await narrator.startNarration(
                fileURL: fileURL, title: title.trimmingCharacters(in: .whitespaces), sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage, voiceId: voiceId, output: output
            )
            model.narrations.add(job, serverId: serverId)
            try? FileManager.default.removeItem(at: fileURL)
            Haptics.impact(.medium)
            dismiss()
        } catch {
            errorMessage = (error as? SourceError)?.userMessage ?? error.localizedDescription
        }
    }

    static func price(_ cents: Int, _ currency: String) -> String {
        (Decimal(cents) / 100).formatted(.currency(code: currency))
    }
}

/// Narrations under way, with how far each is; a failed one says why and can be dropped, a
/// finished one points at its book.
struct NarrationsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let active = model.narrations.active
        if !active.isEmpty {
            Section("Narrating") {
                ForEach(active) { entry in
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text(entry.title).lineLimit(1)
                        if entry.stage == "failed" {
                            Text(entry.error ?? String(localized: "The narration failed.")).font(.caption).foregroundStyle(Theme.Colors.error)
                        } else if entry.stage == "complete" {
                            Text("Done · \(NarrateBookView.price(entry.quotedPriceCents, entry.currency))").font(.caption).foregroundStyle(Theme.Colors.muted)
                        } else {
                            ProgressView(value: Self.fraction(entry)).tint(Theme.Colors.accent)
                            Text(Self.stageText(entry)).font(.caption).foregroundStyle(Theme.Colors.muted)
                        }
                    }
                    .accessibilityIdentifier("narration.\(entry.id)")
                    .swipeActions {
                        if entry.isTerminal {
                            Button("Remove", role: .destructive) { model.narrations.forget(entry.id) }
                        }
                    }
                }
            }
        }
    }

    /// Stages done over stages there are, with the chapters narrated so far inside the one that
    /// counts them.
    private static func fraction(_ entry: NarrationManager.Entry) -> Double {
        guard !entry.stages.isEmpty, let index = entry.stages.firstIndex(of: entry.stage) else { return 0 }
        let within = entry.chaptersTotal > 0 ? Double(entry.chaptersDone) / Double(entry.chaptersTotal) : 0
        return (Double(index) + within) / Double(entry.stages.count)
    }

    private static func stageText(_ entry: NarrationManager.Entry) -> String {
        switch entry.stage {
        case "queued": String(localized: "Waiting its turn")
        case "extracting": String(localized: "Reading the ebook")
        case "translating": String(localized: "Translating")
        case "narrating": entry.chaptersTotal > 0 ? String(localized: "Narrating · chapter \(entry.chaptersDone + 1) of \(entry.chaptersTotal)") : String(localized: "Narrating")
        case "assembling": String(localized: "Putting the book together")
        default: entry.stage
        }
    }
}
