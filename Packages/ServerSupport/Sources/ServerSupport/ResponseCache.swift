import CryptoKit
import Foundation

/// Saved answers to read requests, so a screen seen once opens again with no network.
public protocol ResponseCache: Sendable {
    func data(forKey key: String) -> Data?
    func store(_ data: Data, forKey key: String)
    func removeAll()
}

/// One file per answer, named by a hash of the request. Lives in Caches: iOS may clear it when
/// space runs low, which only means a screen needs the network again.
public final class DiskResponseCache: ResponseCache, @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("server-responses", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    public func data(forKey key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return try? Data(contentsOf: fileURL(key))
    }

    public func store(_ data: Data, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        try? data.write(to: fileURL(key), options: .atomic)
    }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func fileURL(_ key: String) -> URL {
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name)
    }
}

/// Whether the app is offline, readable from any thread: requests ask from their own tasks.
public final class OfflineSwitch: @unchecked Sendable {
    private var value = false
    private let lock = NSLock()

    public init() {}

    public var isOn: Bool {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}
