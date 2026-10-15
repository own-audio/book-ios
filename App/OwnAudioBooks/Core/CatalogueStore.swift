import BookLibrary
import Foundation

/// own.audio's change-feed state per server, kept between launches in Application Support so
/// the library is there before the first request and only the changes are fetched.
struct CatalogueStore: Sendable {
    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("catalogues", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    func load(serverId: UUID) -> FeedState? {
        guard let data = try? Data(contentsOf: file(serverId)) else { return nil }
        return try? JSONDecoder().decode(FeedState.self, from: data)
    }

    func save(_ state: FeedState, serverId: UUID) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: file(serverId), options: .atomic)
    }

    func remove(serverId: UUID) {
        try? FileManager.default.removeItem(at: file(serverId))
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func file(_ serverId: UUID) -> URL {
        directory.appendingPathComponent("\(serverId.uuidString).json")
    }
}
