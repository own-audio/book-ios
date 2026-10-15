import BookLibrary
import Foundation
import Observation

/// Books on their way from the phone to an own.audio server: each file copied into the app's
/// own folder first (the picker's access to it ends with the screen), then put into storage
/// through a background `URLSession`, which goes on when the app is in the background or
/// gone; when every file is there, one call makes the book, with an idempotency key so a retry
/// cannot make two. An index keeps every import, so a kill mid-way is resumed, not lost.
@Observable
@MainActor
final class ImportManager: NSObject {
    struct File: Codable, Equatable, Identifiable {
        let id: String
        var fileName: String
        var title: String?
        var contentType: String
        var sizeBytes: Int64
        /// Where the copy lives, under the imports folder.
        let localName: String
        var uploadId: String?
        var uploadURL: URL?
        var uploadMethod: String?
        var uploadHeaders: [String: String]?
        var uploadExpiresAt: Date?
        var uploaded = false
    }

    struct Import: Codable, Equatable, Identifiable {
        let id: String
        let serverId: UUID
        var title: String?
        var authors: [String]
        var narrators: [String]
        var description: String?
        var visibility: Visibility
        var cover: File?
        var files: [File]
        let startedAt: Date
        var bookId: String?
        var failure: String?

        var totalBytes: Int64 { files.reduce(0) { $0 + $1.sizeBytes } + (cover?.sizeBytes ?? 0) }
        var isDone: Bool { bookId != nil }
    }

    private(set) var imports: [String: Import] = [:]
    /// Bytes sent per file, for progress.
    private var sent: [String: Int64] = [:]
    var uploaderProvider: ((UUID) -> (any BookUploader)?)?
    var backgroundCompletion: (() -> Void)?

    static let sessionIdentifier = "audio.own.bookplayer.imports"
    private let directory: URL
    private let indexURL: URL
    private var session: URLSession!
    private var tasks: [String: URLSessionUploadTask] = [:]
    private var creating: Set<String> = []

    override init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("Imports", isDirectory: true)
        indexURL = directory.appendingPathComponent("index.json")
        super.init()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        if let data = try? Data(contentsOf: indexURL), let saved = try? JSONDecoder().decode([String: Import].self, from: data) { imports = saved }
    }

    var active: [Import] { imports.values.filter { !$0.isDone }.sorted { $0.startedAt > $1.startedAt } }

    /// 0…1 of the bytes sent.
    func progress(of importId: String) -> Double {
        guard let item = imports[importId], item.totalBytes > 0 else { return 0 }
        var have: Int64 = 0
        for file in item.files + [item.cover].compactMap({ $0 }) {
            have += file.uploaded ? file.sizeBytes : (sent[file.id] ?? 0)
        }
        return min(1, Double(have) / Double(item.totalBytes))
    }

    // MARK: - Starting

    struct Picked {
        let url: URL
        let title: String?
        let contentType: String
    }

    /// Copies the picked files in (the caller holds the picker's access while this runs) and
    /// starts the uploads.
    func start(serverId: UUID, title: String?, authors: [String], narrators: [String], description: String?, visibility: Visibility, cover: Picked?, files: [Picked]) throws -> Import {
        let id = UUID().uuidString
        let folder = directory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func copy(_ picked: Picked, index: Int) throws -> File {
            let localName = "\(id)/\(index)-\(picked.url.lastPathComponent)"
            let destination = directory.appendingPathComponent(localName)
            try FileManager.default.copyItem(at: picked.url, to: destination)
            let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
            return File(id: UUID().uuidString, fileName: picked.url.lastPathComponent, title: picked.title, contentType: picked.contentType, sizeBytes: size, localName: localName)
        }
        let item = Import(
            id: id, serverId: serverId, title: title, authors: authors, narrators: narrators, description: description, visibility: visibility,
            cover: try cover.map { try copy($0, index: 0) }, files: try files.enumerated().map { try copy($1, index: $0 + 1) }, startedAt: Date()
        )
        imports[id] = item
        save()
        Task { await self.advance(id) }
        return item
    }

    func retry(_ importId: String) {
        imports[importId]?.failure = nil
        save()
        Task { await self.advance(importId) }
    }

    func cancel(_ importId: String) {
        for (key, task) in tasks where key.hasPrefix(importId + "#") {
            task.cancel()
            tasks[key] = nil
        }
        imports[importId] = nil
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(importId))
        save()
    }

    /// Forgets a finished import and its copies.
    func forget(_ importId: String) {
        guard imports[importId]?.isDone == true else { return }
        cancel(importId)
    }

    /// At launch and after the session was recreated: what is still to do.
    func resume() {
        session.getAllTasks { [weak self] running in
            Task { @MainActor [weak self] in
                guard let self else { return }
                for task in running as? [URLSessionUploadTask] ?? [] {
                    if let key = task.taskDescription { self.tasks[key] = task }
                }
                for item in self.imports.values where !item.isDone && item.failure == nil { await self.advance(item.id) }
            }
        }
    }

    // MARK: - Work

    /// Asks for links and starts uploads for what has none; makes the book when every file
    /// is up.
    private func advance(_ importId: String) async {
        guard var item = imports[importId], !item.isDone, let uploader = uploaderProvider?(item.serverId) else { return }
        var pending: [File] = item.files + [item.cover].compactMap { $0 }
        pending = pending.filter { !$0.uploaded }
        if pending.isEmpty {
            await createBook(importId, with: uploader)
            return
        }
        for file in pending where tasks[importId + "#" + file.id] == nil {
            do {
                var file = file
                if file.uploadURL == nil || (file.uploadExpiresAt ?? .distantPast) < Date().addingTimeInterval(300) {
                    let target = try await uploader.uploadTarget(kind: file.id == item.cover?.id ? "cover" : "audio", fileName: file.fileName, contentType: file.contentType, sizeBytes: file.sizeBytes)
                    file.uploadId = target.uploadId
                    file.uploadURL = target.url
                    file.uploadMethod = target.method
                    file.uploadHeaders = target.headers
                    file.uploadExpiresAt = target.expiresAt
                    item = imports[importId] ?? item
                    if let index = item.files.firstIndex(where: { $0.id == file.id }) { item.files[index] = file } else { item.cover = file }
                    imports[importId] = item
                    save()
                }
                guard let url = file.uploadURL else { continue }
                var request = URLRequest(url: url)
                request.httpMethod = file.uploadMethod ?? "PUT"
                for (key, value) in file.uploadHeaders ?? [:] { request.setValue(value, forHTTPHeaderField: key) }
                let task = session.uploadTask(with: request, fromFile: directory.appendingPathComponent(file.localName))
                task.taskDescription = importId + "#" + file.id
                tasks[task.taskDescription!] = task
                task.resume()
            } catch {
                imports[importId]?.failure = (error as? SourceError)?.userMessage ?? error.localizedDescription
                save()
                return
            }
        }
    }

    private func createBook(_ importId: String, with uploader: any BookUploader) async {
        guard let item = imports[importId], !creating.contains(importId) else { return }
        creating.insert(importId)
        defer { creating.remove(importId) }
        do {
            let files = item.files.compactMap { file in file.uploadId.map { ImportedFile(uploadId: $0, fileName: file.fileName, title: file.title) } }
            let book = try await uploader.createBook(
                title: item.title, authors: item.authors, narrators: item.narrators, description: item.description, visibility: item.visibility,
                coverUploadId: item.cover?.uploadId, files: files, importId: item.id
            )
            imports[importId]?.bookId = book.id
            imports[importId]?.failure = nil
            save()
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(importId))
        } catch {
            imports[importId]?.failure = (error as? SourceError)?.userMessage ?? error.localizedDescription
            save()
        }
    }

    private func finished(key: String, status: Int?, error: Error?) {
        let parts = key.split(separator: "#", maxSplits: 1).map(String.init)
        guard parts.count == 2, var item = imports[parts[0]] else { return }
        let (importId, fileId) = (parts[0], parts[1])
        if let error {
            if (error as NSError).code != NSURLErrorCancelled { item.failure = error.localizedDescription }
        } else if let status, (200..<300).contains(status) {
            if let index = item.files.firstIndex(where: { $0.id == fileId }) { item.files[index].uploaded = true } else if item.cover?.id == fileId { item.cover?.uploaded = true }
        } else {
            item.failure = String(localized: "The storage refused the file (\(status ?? 0)).")
        }
        imports[importId] = item
        sent[fileId] = nil
        save()
        if item.failure == nil { Task { await self.advance(importId) } }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(imports) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}

extension ImportManager: URLSessionTaskDelegate {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let key = task.taskDescription ?? ""
        let fileId = String(key.split(separator: "#", maxSplits: 1).last ?? "")
        Task { @MainActor in self.sent[fileId] = totalBytesSent }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let key = task.taskDescription ?? ""
        let status = (task.response as? HTTPURLResponse)?.statusCode
        Task { @MainActor in
            self.tasks[key] = nil
            self.finished(key: key, status: status, error: error)
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            self.backgroundCompletion?()
            self.backgroundCompletion = nil
        }
    }
}
