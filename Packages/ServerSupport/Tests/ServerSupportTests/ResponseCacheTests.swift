import Foundation
import Testing

@testable import ServerSupport

@Suite("DiskResponseCache")
struct ResponseCacheTests {
    @Test("an answer stored under a key is read back, and removeAll forgets it")
    func roundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cache = DiskResponseCache(directory: dir)
        #expect(cache.data(forKey: "books?limit=1") == nil)
        cache.store(Data("[]".utf8), forKey: "books?limit=1")
        #expect(cache.data(forKey: "books?limit=1") == Data("[]".utf8))
        cache.removeAll()
        #expect(cache.data(forKey: "books?limit=1") == nil)
    }
}
