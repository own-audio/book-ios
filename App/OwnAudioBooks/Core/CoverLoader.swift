import Foundation
import UIKit

/// Covers, cached in memory and on disk by server, book and size — not by URL, because
/// own.audio's signed links change every week and the same cover would be fetched again.
actor CoverLoader {
    private let memory = NSCache<NSString, UIImage>()
    private let directory: URL
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    init() {
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        memory.countLimit = 300
    }

    /// `compositeId` is a `BookID`; `url` is where the cover is now, asked for only on a miss.
    /// `fresh` is asked once when that link does not load: a link from a synced record can have
    /// expired, or point at an address the server no longer gives out.
    func image(
        compositeId: String,
        size: Int,
        url: @escaping @Sendable () async -> URL?,
        fresh: (@Sendable () async -> URL?)? = nil
    ) async -> UIImage? {
        let key = "\(compositeId)@\(size)"
        if let cached = memory.object(forKey: key as NSString) { return cached }
        if let task = inFlight[key] { return await task.value }
        let task = Task { await load(key: key, compositeId: compositeId, size: size, url: url, fresh: fresh) }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        return image
    }

    func clear() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func load(
        key: String,
        compositeId: String,
        size: Int,
        url: @escaping @Sendable () async -> URL?,
        fresh: (@Sendable () async -> URL?)?
    ) async -> UIImage? {
        let file = directory.appendingPathComponent(Self.fileName(compositeId: compositeId, size: size))
        if let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
            memory.setObject(image, forKey: key as NSString)
            return image
        }
        let first = await url()
        var loaded = await Self.fetch(first)
        if loaded == nil, let fresh, let second = await fresh(), second != first {
            loaded = await Self.fetch(second)
        }
        guard let (data, image) = loaded else { return cachedOtherSize(compositeId: compositeId, near: size) }
        memory.setObject(image, forKey: key as NSString)
        try? data.write(to: file, options: .atomic)
        return image
    }

    private static func fetch(_ url: URL?) async -> (Data, UIImage)? {
        guard let url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let image = UIImage(data: data)
        else { return nil }
        return (data, image)
    }

    /// Offline, or the server is down: any size of the same cover beats a placeholder.
    private func cachedOtherSize(compositeId: String, near size: Int) -> UIImage? {
        let prefix = Self.encode(compositeId) + "@"
        let sizes = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix(prefix) }
            .compactMap { Int($0.dropFirst(prefix.count)) }
        for candidate in sizes.filter({ $0 >= size }).sorted() + sizes.filter({ $0 < size }).sorted(by: >) {
            if let data = try? Data(contentsOf: directory.appendingPathComponent(Self.fileName(compositeId: compositeId, size: candidate))),
               let image = UIImage(data: data) { return image }
        }
        return nil
    }

    private static func fileName(compositeId: String, size: Int) -> String { "\(encode(compositeId))@\(size)" }

    private static func encode(_ text: String) -> String {
        Data(text.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
    }
}
