import Foundation

/// A book id that names its server too, so the player and the covers can tell books of several
/// servers apart: `<server UUID>|<the server's id>`.
enum BookID {
    static func make(serverId: UUID, bookId: String) -> String {
        "\(serverId.uuidString)|\(bookId)"
    }

    static func parse(_ composite: String) -> (serverId: UUID, bookId: String)? {
        guard let bar = composite.firstIndex(of: "|"), let serverId = UUID(uuidString: String(composite[..<bar])) else { return nil }
        return (serverId, String(composite[composite.index(after: bar)...]))
    }
}
