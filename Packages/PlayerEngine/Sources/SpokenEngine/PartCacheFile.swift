import Foundation

/// One streamed file's bytes on disk: a sparse file the size of the original, with the ranges
/// fetched so far, and a small JSON map beside it saying which ranges those are, how long the
/// file is and what type it is. The map survives a relaunch, so a part heard once plays its
/// fetched stretch with no network later.
final class PartCacheFile: @unchecked Sendable {
    struct Map: Codable, Equatable {
        var totalLength: Int64?
        /// The type as AVFoundation wants it (`public.mp3`, `com.apple.m4a-audio`, …).
        var uti: String?
        var ranges = ByteRanges()
        var lastUsed = Date()
    }

    let key: String
    let dataURL: URL
    let mapURL: URL
    private let lock = NSLock()
    private var map: Map

    init(directory: URL, key: String) {
        self.key = key
        let name = Self.fileName(key)
        dataURL = directory.appendingPathComponent(name + ".part")
        mapURL = directory.appendingPathComponent(name + ".json")
        let loaded = (try? Data(contentsOf: mapURL)).flatMap { try? JSONDecoder().decode(Map.self, from: $0) }
        // A map without its data (or the other way round) is nothing to trust.
        if let loaded, FileManager.default.fileExists(atPath: dataURL.path) {
            map = loaded
        } else {
            map = Map()
            try? FileManager.default.removeItem(at: dataURL)
        }
    }

    var snapshot: Map { lock.withLock { map } }
    var totalLength: Int64? { lock.withLock { map.totalLength } }
    var uti: String? { lock.withLock { map.uti } }
    var storedBytes: Int64 { lock.withLock { map.ranges.byteCount } }

    func contiguousEnd(from offset: Int64) -> Int64 { lock.withLock { map.ranges.contiguousEnd(from: offset) } }
    func nextStored(after offset: Int64) -> Int64? { lock.withLock { map.ranges.nextStored(after: offset) } }
    func missing(in range: Range<Int64>) -> [Range<Int64>] { lock.withLock { map.ranges.missing(in: range) } }
    var isComplete: Bool {
        lock.withLock { map.totalLength.map { map.ranges.contains(0..<$0) && $0 > 0 } ?? false }
    }

    func setInfo(totalLength: Int64, uti: String) {
        lock.withLock {
            // A different length is a different file behind the same id: start again.
            if let known = map.totalLength, known != totalLength {
                map = Map()
                try? FileManager.default.removeItem(at: dataURL)
            }
            map.totalLength = totalLength
            map.uti = uti
            saveLocked()
        }
    }

    /// Bytes on disk, or nil when any of them is not.
    func read(_ range: Range<Int64>) -> Data? {
        lock.withLock {
            guard map.ranges.contains(range), let handle = try? FileHandle(forReadingFrom: dataURL) else { return nil }
            defer { try? handle.close() }
            do {
                try handle.seek(toOffset: UInt64(range.lowerBound))
                return try handle.read(upToCount: Int(range.upperBound - range.lowerBound))
            } catch {
                return nil
            }
        }
    }

    func write(_ data: Data, at offset: Int64) {
        guard !data.isEmpty else { return }
        lock.withLock {
            if !FileManager.default.fileExists(atPath: dataURL.path) {
                FileManager.default.createFile(atPath: dataURL.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: dataURL) else { return }
            defer { try? handle.close() }
            do {
                // Writing past the end leaves a hole the file system does not store.
                try handle.seek(toOffset: UInt64(offset))
                try handle.write(contentsOf: data)
            } catch {
                return
            }
            map.ranges.insert(offset..<offset + Int64(data.count))
            map.lastUsed = Date()
            saveLocked()
        }
    }

    func touch() {
        lock.withLock {
            map.lastUsed = Date()
            saveLocked()
        }
    }

    func remove() {
        lock.withLock {
            try? FileManager.default.removeItem(at: dataURL)
            try? FileManager.default.removeItem(at: mapURL)
            map = Map()
        }
    }

    /// Bytes the file takes on disk (holes not counted).
    var diskBytes: Int64 {
        let values = try? dataURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        return Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
    }

    private func saveLocked() {
        guard let data = try? JSONEncoder().encode(map) else { return }
        try? data.write(to: mapURL, options: .atomic)
    }

    static func fileName(_ key: String) -> String {
        Data(key.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
    }

    static func key(fromFileName name: String) -> String? {
        let base64 = name.replacingOccurrences(of: "_", with: "/").replacingOccurrences(of: "-", with: "+")
        return Data(base64Encoded: base64).flatMap { String(data: $0, encoding: .utf8) }
    }
}
