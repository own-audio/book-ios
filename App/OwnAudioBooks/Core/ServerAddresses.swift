import BookLibrary
import Foundation
import UIKit

// The server page's addresses and pictures, as in the podcasts app: addresses the listener adds
// (a home network, a VPN such as Tailscale), one to always use, and each server's own icon.

extension AppModel {
    /// An address to try as well; without a scheme, http, as home servers mostly are.
    func addAddress(_ text: String, to id: UUID) async throws {
        guard var record = server(id) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard let url = URL(string: withScheme), url.host() != nil else { throw AddServerError.badAddress }
        guard !record.candidateAddresses.contains(where: { ServerRecord.normalized($0.url) == ServerRecord.normalized(url) }) else { return }
        record.addresses.append(ServerAddress(url: url, origin: .user))
        try await update(record)
        await chooseAddresses()
    }

    func removeAddress(_ url: URL, from id: UUID) async {
        guard var record = server(id) else { return }
        record.addresses.removeAll { $0.url == url }
        if case .fixed(url) = record.connection { record.connection = .automatic }
        try? await update(record)
        await chooseAddresses()
    }

    /// nil is automatic: the fastest address that answers as this server, on each network.
    func setFixedAddress(_ url: URL?, for id: UUID) async {
        guard var record = server(id) else { return }
        record.connection = url.map { .fixed($0) } ?? .automatic
        try? await update(record)
        if url == nil { await chooseAddresses() }
    }

    /// Audiobookshelf's own icon, from disk, else asked of the server once.
    func loadServerIcons() async {
        for record in servers where record.kind == .audiobookshelf {
            let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("server-icons", isDirectory: true).appendingPathComponent("\(record.id.uuidString).png")
            if serverIcons[record.id] == nil, let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
                serverIcons[record.id] = image
                continue
            }
            guard serverIcons[record.id] == nil, !isOffline else { continue }
            let host = activeAddresses[record.id] ?? record.host
            for name in ["icon192.png", "icon64.png", "favicon.ico"] {
                guard let (data, response) = try? await URLSession.shared.data(from: host.appending(path: name)),
                      (response as? HTTPURLResponse)?.statusCode == 200, (response.mimeType ?? "").hasPrefix("image/"),
                      let image = UIImage(data: data), image.size.width >= 16 else { continue }
                serverIcons[record.id] = image
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? image.pngData()?.write(to: file, options: .atomic)
                break
            }
        }
    }
}
