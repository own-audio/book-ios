import Foundation

/// Which bytes of a file are on disk: sorted, disjoint half-open ranges, with neighbours merged.
struct ByteRanges: Codable, Equatable, Sendable {
    private(set) var ranges: [Range<Int64>] = []

    init(_ ranges: [Range<Int64>] = []) {
        for range in ranges { insert(range) }
    }

    var byteCount: Int64 { ranges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) } }

    mutating func insert(_ range: Range<Int64>) {
        guard !range.isEmpty else { return }
        var merged = range
        var kept: [Range<Int64>] = []
        kept.reserveCapacity(ranges.count + 1)
        for existing in ranges {
            if existing.upperBound < merged.lowerBound || existing.lowerBound > merged.upperBound {
                kept.append(existing)
            } else {
                merged = min(existing.lowerBound, merged.lowerBound)..<max(existing.upperBound, merged.upperBound)
            }
        }
        kept.append(merged)
        ranges = kept.sorted { $0.lowerBound < $1.lowerBound }
    }

    func contains(_ range: Range<Int64>) -> Bool {
        range.isEmpty || ranges.contains { $0.lowerBound <= range.lowerBound && $0.upperBound >= range.upperBound }
    }

    /// Where the bytes on disk that start at `offset` run out; `offset` itself when that byte
    /// is not on disk.
    func contiguousEnd(from offset: Int64) -> Int64 {
        ranges.first { $0.lowerBound <= offset && $0.upperBound > offset }?.upperBound ?? offset
    }

    /// The first byte on disk at or after `offset`, if any: a fetch stops there.
    func nextStored(after offset: Int64) -> Int64? {
        ranges.first { $0.lowerBound > offset }?.lowerBound
    }

    /// The pieces of `range` that are not on disk.
    func missing(in range: Range<Int64>) -> [Range<Int64>] {
        var out: [Range<Int64>] = []
        var cursor = range.lowerBound
        for existing in ranges where existing.upperBound > cursor {
            if existing.lowerBound >= range.upperBound { break }
            if existing.lowerBound > cursor { out.append(cursor..<min(existing.lowerBound, range.upperBound)) }
            cursor = max(cursor, existing.upperBound)
            if cursor >= range.upperBound { break }
        }
        if cursor < range.upperBound { out.append(cursor..<range.upperBound) }
        return out
    }
}
