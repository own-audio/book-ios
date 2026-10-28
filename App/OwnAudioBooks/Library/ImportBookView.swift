import BookLibrary
import PhotosUI
import SpokenEngine
import SwiftUI
import UniformTypeIdentifiers

/// A book from the phone: audio files from the Files app, the tags read to fill the form,
/// the files in order, a cover, who sees it — then the upload goes on by itself.
struct ImportBookView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let serverId: UUID

    struct PickedFile: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        var title: String?
        var durationMs: Int64
        let contentType: String
    }

    @State private var files: [PickedFile] = []
    @State private var title = ""
    @State private var author = ""
    @State private var narrator = ""
    @State private var visibility: BookLibrary.Visibility = .private
    @State private var coverItem: PhotosPickerItem?
    @State private var coverData: Data?
    @State private var isPicking = false
    @State private var isReading = false
    @State private var errorMessage: String?
    @State private var isConfirmingMobile = false

    private var totalBytes: Int64 {
        files.reduce(0) { $0 + ((try? $1.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0) }
    }

    private var canImport: Bool { !files.isEmpty && !isReading }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { isPicking = true } label: { Label(files.isEmpty ? "Choose Audio Files" : "Add More Files", systemImage: "doc.badge.plus") }
                        .accessibilityIdentifier("import.pick")
                    if isReading { ProgressView() }
                    ForEach(files) { file in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(file.title ?? file.url.lastPathComponent).lineLimit(1)
                                Text(file.url.lastPathComponent).font(.caption).foregroundStyle(Theme.Colors.muted).lineLimit(1)
                            }
                            Spacer()
                            Text(ProgressText.clock(file.durationMs)).font(.caption.monospacedDigit()).foregroundStyle(Theme.Colors.muted)
                        }
                    }
                    .onMove { files.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { files.remove(atOffsets: $0) }
                } header: {
                    Text("Files, in playing order")
                } footer: {
                    if !files.isEmpty {
                        Text("\(files.count) files · \(ProgressText.length(files.reduce(0) { $0 + $1.durationMs })) · \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)). Drag to reorder.")
                    }
                }
                Section("Book") {
                    TextField("Title", text: $title).accessibilityIdentifier("import.title")
                    TextField("Author", text: $author).accessibilityIdentifier("import.author")
                    TextField("Narrator", text: $narrator).accessibilityIdentifier("import.narrator")
                    PhotosPicker(selection: $coverItem, matching: .images) {
                        HStack {
                            Text("Cover")
                            Spacer()
                            if let coverData, let image = UIImage(data: coverData) {
                                Image(uiImage: image).resizable().scaledToFill().frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 6))
                            } else {
                                Text("From the file, or choose").foregroundStyle(Theme.Colors.muted)
                            }
                        }
                    }
                    Picker("Who sees it", selection: $visibility) {
                        Text("Only me").tag(BookLibrary.Visibility.private)
                        Text("The family").tag(BookLibrary.Visibility.family)
                    }
                    .accessibilityIdentifier("import.visibility")
                }
                if let errorMessage {
                    Section { Label(errorMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.Colors.error) }
                }
                Section {
                    Button {
                        if model.network.isExpensive, totalBytes > 100 << 20 { isConfirmingMobile = true } else { start() }
                    } label: {
                        HStack { Spacer(); Text("Add to Library").bold(); Spacer() }
                    }
                    .disabled(!canImport)
                    .accessibilityIdentifier("import.start")
                } footer: {
                    Text("The files are copied and uploaded in the background; you can leave this screen. The book appears in the library once the upload is done.")
                }
            }
            .navigationTitle("Import a Book")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { EditButton() }
            }
            .sheet(isPresented: $isPicking) {
                DocumentPicker(types: [.audio, .mp3, .mpeg4Audio, .folder]) { urls in Task { await add(urls) } }
            }
            .onChange(of: coverItem) { _, item in
                Task { coverData = try? await item?.loadTransferable(type: Data.self) }
            }
            .confirmationDialog("Upload \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)) over mobile data?", isPresented: $isConfirmingMobile, titleVisibility: .visible) {
                Button("Upload Now") { start() }
            }
        }
    }

    /// Reads the picked files (and the audio inside picked folders), in name order, filling
    /// the form from the first file's tags.
    private func add(_ urls: [URL]) async {
        isReading = true
        defer { isReading = false }
        var audio: [URL] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let contents = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                audio += contents.filter { ImportMetadata.audioExtensions.contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            } else if ImportMetadata.audioExtensions.contains(url.pathExtension.lowercased()) {
                audio.append(url)
            }
            // The picker's access ends with this screen: a copy in the app's own folder keeps it.
            for source in audio where !files.contains(where: { $0.url.lastPathComponent == source.lastPathComponent }) {
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)-\(source.lastPathComponent)")
                let innerScoped = source.startAccessingSecurityScopedResource()
                defer { if innerScoped { source.stopAccessingSecurityScopedResource() } }
                guard (try? FileManager.default.copyItem(at: source, to: copy)) != nil else { continue }
                let meta = await ImportMetadata.read(copy)
                files.append(PickedFile(url: copy, title: meta.title, durationMs: meta.durationMs, contentType: meta.contentType))
                if title.isEmpty, let album = meta.album ?? meta.title { title = album }
                if author.isEmpty, let artist = meta.artist { author = artist }
                if coverData == nil, let artwork = meta.artwork { coverData = artwork }
            }
            audio.removeAll()
        }
    }

    private func start() {
        do {
            var cover: ImportManager.Picked?
            if let coverData {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("import-cover-\(UUID().uuidString).jpg")
                try coverData.write(to: url)
                cover = ImportManager.Picked(url: url, title: nil, contentType: "image/jpeg")
            }
            _ = try model.imports.start(
                serverId: serverId, title: title.isEmpty ? nil : title,
                authors: author.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                narrators: narrator.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                description: nil, visibility: visibility, cover: cover,
                files: files.map { ImportManager.Picked(url: $0.url, title: $0.title, contentType: $0.contentType) }
            )
            for file in files { try? FileManager.default.removeItem(at: file.url) }
            Haptics.impact(.medium)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// The Files app's picker, for audio files and folders of them.
struct DocumentPicker: UIViewControllerRepresentable {
    let types: [UTType]
    let onPick: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onPick(urls) }
    }
}

/// Imports on their way, with a bar each; a failed one can be tried again or dropped.
struct ImportsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let active = model.imports.active
        if !active.isEmpty {
            Section("Importing") {
                ForEach(active) { item in
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text(item.title ?? item.files.first?.fileName ?? "Book").lineLimit(1)
                        if let failure = item.failure {
                            Text(failure).font(.caption).foregroundStyle(Theme.Colors.error)
                            HStack {
                                Button("Try Again") { model.imports.retry(item.id) }
                                Button("Remove", role: .destructive) { model.imports.cancel(item.id) }
                            }
                            .font(.caption.weight(.semibold))
                        } else {
                            ProgressView(value: model.imports.progress(of: item.id))
                            Text("\(item.files.count) files · \(ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file))").font(.caption).foregroundStyle(Theme.Colors.muted)
                        }
                    }
                    .swipeActions { Button(role: .destructive) { model.imports.cancel(item.id) } label: { Label("Cancel", systemImage: "xmark") } }
                }
            }
        }
    }
}
