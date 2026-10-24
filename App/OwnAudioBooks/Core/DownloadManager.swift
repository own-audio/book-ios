import BookLibrary
import Foundation
import Observation
import PlayerCore
import UIKit

/// Books kept on the phone, file by file, through a background `URLSession`: a download goes on
/// when the app is in the background or gone, and picks up where it stopped after a kill.
///
/// Files live in Application Support, which iOS doesn't clear the way it clears Caches, and are
/// excluded from iCloud backup: they can always be downloaded again. An index file records
/// each book and its files, so the offline screens work with no network at all.
@Observable
@MainActor
final class DownloadManager: NSObject {
    enum State: Equatable {
        case downloading(fraction: Double)
        case downloaded
        case failed(String)
    }

    /// A book on the phone (or on its way): its record as it was, and where its files are.
    struct DownloadedBook: Codable, Equatable, Identifiable {
        let id: String
        let serverId: UUID
        var book: Book
        /// By file id: the local file name, once downloaded.
        var files: [String: String]
        var bytes: Int64
        let startedAt: Date
        var finishedAt: Date?
        var lastPlayedAt: Date?

        var isComplete: Bool { (book.files ?? []).allSatisfy { files[$0.id] != nil } }
    }

    private struct Index: Codable {
        var books: [String: DownloadedBook] = [:]
        /// Resume data of downloads that were interrupted, by task description.
        var resumeData: [String: Data] = [:]
    }

    private(set) var books: [String: DownloadedBook] = [:]
    private(set) var states: [String: State] = [:]
    /// Per file: bytes written so far, for the progress of a book.
    private var written: [String: Int64] = [:]
    private var resumeData: [String: Data] = [:]
    var wifiOnly = false { didSet { if wifiOnly != oldValue { restart() } } }
    /// What the app asks for a file's URL; the session can't, it only knows ids.
    var urlProvider: ((_ compositeId: String, _ fileId: String) async throws -> URL)?
    /// Called when the session reports that its background work is done, so the app can tell
    /// iOS (`handleEventsForBackgroundURLSession`).
    var backgroundCompletion: (() -> Void)?

    /// The session reports bytes many times a second; the main thread hears of it twice.
    @ObservationIgnored nonisolated let progressThrottle = ProgressThrottle(interval: 0.5)
    private let directory: URL
    private let indexURL: URL
    private var session: URLSession!
    private var tasks: [String: URLSessionDownloadTask] = [:]
    static let sessionIdentifier = "audio.own.bookplayer.downloads"

    override init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("Downloads", isDirectory: true)
        indexURL = directory.appendingPathComponent("index.json")
        super.init()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        loadIndex()
    }

    // MARK: - Reading

    var totalBytes: Int64 { books.values.reduce(0) { $0 + $1.bytes } }

    func state(of compositeId: String) -> State? { states[compositeId] }

    func isDownloaded(_ compositeId: String) -> Bool { books[compositeId]?.isComplete == true }

    func downloaded(_ compositeId: String) -> DownloadedBook? {
        books[compositeId].flatMap { $0.isComplete ? $0 : nil }
    }

    /// Every complete book of a server, newest download first.
    func downloadedBooks(serverId: UUID) -> [DownloadedBook] {
        books.values.filter { $0.serverId == serverId && $0.isComplete }.sorted { ($0.finishedAt ?? $0.startedAt) > ($1.finishedAt ?? $1.startedAt) }
    }

    /// The local file of one part of a downloaded book.
    func fileURL(compositeId: String, fileId: String) -> URL? {
        books[compositeId]?.files[fileId].map { directory.appendingPathComponent($0) }
    }

    func notePlayed(_ compositeId: String) {
        guard books[compositeId] != nil else { return }
        books[compositeId]?.lastPlayedAt = Date()
        saveIndex()
    }

    // MARK: - Changing

    /// Downloads every file of `book` (a detail, with its files).
    func download(_ book: Book, serverId: UUID) {
        let id = BookID.make(serverId: serverId, bookId: book.id)
        guard let files = book.files, !files.isEmpty, books[id] == nil || books[id]?.isComplete == false else { return }
        if books[id] == nil {
            books[id] = DownloadedBook(id: id, serverId: serverId, book: book, files: [:], bytes: 0, startedAt: Date())
        }
        states[id] = .downloading(fraction: 0)
        saveIndex()
        for file in files where books[id]?.files[file.id] == nil {
            start(compositeId: id, fileId: file.id)
        }
    }

    func remove(_ compositeId: String) {
        for (key, task) in tasks where key.hasPrefix(compositeId + "#") {
            task.cancel()
            tasks[key] = nil
        }
        if let book = books.removeValue(forKey: compositeId) {
            for name in book.files.values { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
        }
        resumeData = resumeData.filter { !$0.key.hasPrefix(compositeId + "#") }
        states[compositeId] = nil
        written = written.filter { !$0.key.hasPrefix(compositeId + "#") }
        saveIndex()
    }

    func removeAll(serverId: UUID? = nil) {
        for id in books.keys where serverId == nil || books[id]?.serverId == serverId { remove(id) }
    }

    /// Lets go of what the cap no longer allows; `protected` is the book playing now.
    func enforce(capBytes: Int64?, protected: String?) {
        let policy = EvictionPolicy(capBytes: capBytes)
        let candidates = books.values.filter(\.isComplete).map {
            EvictionPolicy.Candidate(id: $0.id, bytes: $0.bytes, isFinished: false, lastUsedAt: $0.lastPlayedAt ?? $0.finishedAt ?? $0.startedAt)
        }
        for id in policy.evictions(from: candidates, protected: protected) { remove(id) }
    }

    /// Tries failed downloads again.
    func retry(_ compositeId: String) {
        guard let book = books[compositeId], !book.isComplete else { return }
        states[compositeId] = .downloading(fraction: 0)
        for file in book.book.files ?? [] where book.files[file.id] == nil { start(compositeId: compositeId, fileId: file.id) }
    }

    /// Picks up interrupted downloads: at launch, and after the session was recreated.
    func resume() {
        session.getAllTasks { [weak self] running in
            Task { @MainActor [weak self] in
                guard let self else { return }
                for task in running as? [URLSessionDownloadTask] ?? [] {
                    if let key = task.taskDescription { self.tasks[key] = task }
                }
                for book in self.books.values where !book.isComplete {
                    self.states[book.id] = .downloading(fraction: self.fraction(of: book))
                    for file in book.book.files ?? [] where book.files[file.id] == nil && self.tasks[book.id + "#" + file.id] == nil {
                        self.start(compositeId: book.id, fileId: file.id)
                    }
                }
            }
        }
    }

    private func restart() {
        for (key, task) in tasks {
            task.cancel { [weak self] data in
                Task { @MainActor in
                    if let data { self?.resumeData[key] = data }
                    self?.tasks[key] = nil
                    let parts = key.split(separator: "#", maxSplits: 1).map(String.init)
                    if parts.count == 2 { self?.start(compositeId: parts[0], fileId: parts[1]) }
                }
            }
        }
    }

    // MARK: - Work

    private func start(compositeId: String, fileId: String) {
        let key = compositeId + "#" + fileId
        guard tasks[key] == nil else { return }
        if let data = resumeData.removeValue(forKey: key) {
            let task = session.downloadTask(withResumeData: data)
            task.taskDescription = key
            tasks[key] = task
            task.resume()
            saveIndex()
            return
        }
        guard let urlProvider else { return }
        Task { [weak self] in
            do {
                let url = try await urlProvider(compositeId, fileId)
                guard let self, self.books[compositeId] != nil, self.tasks[key] == nil else { return }
                var request = URLRequest(url: url)
                request.allowsCellularAccess = !self.wifiOnly
                let task = self.session.downloadTask(with: request)
                task.taskDescription = key
                self.tasks[key] = task
                task.resume()
            } catch {
                self?.states[compositeId] = .failed((error as? SourceError)?.userMessage ?? error.localizedDescription)
            }
        }
    }

    private func fraction(of book: DownloadedBook) -> Double {
        let files = book.book.files ?? []
        let expected = files.compactMap(\.sizeBytes).reduce(0, +)
        if expected > 0 {
            let have = files.reduce(Int64(0)) { sum, file in
                sum + (book.files[file.id] != nil ? (file.sizeBytes ?? 0) : (written[book.id + "#" + file.id] ?? 0))
            }
            return min(1, Double(have) / Double(expected))
        }
        return files.isEmpty ? 0 : Double(files.filter { book.files[$0.id] != nil }.count) / Double(files.count)
    }

    private func finished(key: String, file: URL, response: URLResponse?) {
        let parts = key.split(separator: "#", maxSplits: 1).map(String.init)
        guard parts.count == 2, var book = books[parts[0]] else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        let (compositeId, fileId) = (parts[0], parts[1])
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: file)
            states[compositeId] = .failed(String(localized: "The server did not send the file."))
            return
        }
        // AVFoundation types a local file by its extension, so one is worked out: from the
        // bytes, else the server's content type, else what the record says.
        let head = (try? FileHandle(forReadingFrom: file)).flatMap { handle -> Data? in
            defer { try? handle.close() }
            return try? handle.read(upToCount: 12)
        } ?? Data()
        let recorded = book.book.files?.first { $0.id == fileId }?.contentType
        let ext = TrackFileCache.fileExtension(prefix: head) ?? TrackFileCache.fileExtension(mimeType: http.mimeType)
            ?? TrackFileCache.fileExtension(mimeType: recorded) ?? "mp3"
        let name = Self.safeName(key) + "." + ext
        let destination = directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: file, to: destination)
        } catch {
            states[compositeId] = .failed(error.localizedDescription)
            return
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
        book.files[fileId] = name
        book.bytes += bytes
        if book.isComplete {
            book.finishedAt = Date()
            states[compositeId] = .downloaded
        } else {
            states[compositeId] = .downloading(fraction: fraction(of: book))
        }
        books[compositeId] = book
        written[key] = nil
        saveIndex()
    }

    // MARK: - Index

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL), let index = try? JSONDecoder().decode(Index.self, from: data) else { return }
        // Files the index lists but the disk lost are not downloaded any more.
        books = index.books.mapValues { book in
            var book = book
            book.files = book.files.filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.value).path) }
            return book
        }
        resumeData = index.resumeData
        for book in books.values { states[book.id] = book.isComplete ? .downloaded : .downloading(fraction: fraction(of: book)) }
    }

    private func saveIndex() {
        guard let data = try? JSONEncoder().encode(Index(books: books, resumeData: resumeData)) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private static func safeName(_ key: String) -> String {
        Data(key.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    /// The file must be moved before this returns; it is done here, on the session's queue,
    /// and the index is updated on the main actor afterwards.
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let key = downloadTask.taskDescription ?? ""
        let response = downloadTask.response
        let holding = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.moveItem(at: location, to: holding)
        Task { @MainActor in
            self.tasks[key] = nil
            self.finished(key: key, file: holding, response: response)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let key = downloadTask.taskDescription ?? ""
        let done = totalBytesExpectedToWrite > 0 && totalBytesWritten >= totalBytesExpectedToWrite
        guard progressThrottle.shouldPass(key, done: done) else { return }
        Task { @MainActor in
            self.written[key] = totalBytesWritten
            let compositeId = String(key.split(separator: "#", maxSplits: 1).first ?? "")
            if let book = self.books[compositeId], !book.isComplete { self.states[compositeId] = .downloading(fraction: self.fraction(of: book)) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let key = task.taskDescription ?? ""
        let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let cancelled = (error as NSError).code == NSURLErrorCancelled
        Task { @MainActor in
            self.tasks[key] = nil
            if let resume { self.resumeData[key] = resume }
            let compositeId = String(key.split(separator: "#", maxSplits: 1).first ?? "")
            if !cancelled, self.books[compositeId] != nil {
                self.states[compositeId] = .failed(error.localizedDescription)
            }
            self.saveIndex()
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            self.backgroundCompletion?()
            self.backgroundCompletion = nil
        }
    }
}

/// Lets a stream of progress callbacks through at most once per `interval` per key, and always
/// the last one. Called on the download session's queue.
final class ProgressThrottle: @unchecked Sendable {
    private let interval: TimeInterval
    private let lock = NSLock()
    private var lastPassed: [String: Date] = [:]

    init(interval: TimeInterval) {
        self.interval = interval
    }

    func shouldPass(_ key: String, done: Bool = false, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done {
            lastPassed[key] = nil
            return true
        }
        if let last = lastPassed[key], now.timeIntervalSince(last) < interval { return false }
        lastPassed[key] = now
        return true
    }
}
