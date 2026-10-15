import Foundation

/// Which downloads to let go when they outgrow the space the listener allowed: finished books
/// first, then the ones not played for the longest, never the one playing now.
public struct EvictionPolicy: Sendable {
    public struct Candidate: Sendable, Equatable {
        public let id: String
        public let bytes: Int64
        public let isFinished: Bool
        /// The last time it was played, or downloaded when it never was.
        public let lastUsedAt: Date

        public init(id: String, bytes: Int64, isFinished: Bool, lastUsedAt: Date) {
            self.id = id
            self.bytes = bytes
            self.isFinished = isFinished
            self.lastUsedAt = lastUsedAt
        }
    }

    public let capBytes: Int64?

    public init(capBytes: Int64?) {
        self.capBytes = capBytes
    }

    /// The ids to remove, in order, so that what is left fits under the cap; `protected` is
    /// never among them. Nothing with no cap.
    public func evictions(from candidates: [Candidate], protected: String?) -> [String] {
        guard let capBytes else { return [] }
        var total = candidates.reduce(0) { $0 + $1.bytes }
        guard total > capBytes else { return [] }
        let order = candidates
            .filter { $0.id != protected }
            .sorted { a, b in
                if a.isFinished != b.isFinished { return a.isFinished }
                return a.lastUsedAt < b.lastUsedAt
            }
        var out: [String] = []
        for candidate in order where total > capBytes {
            out.append(candidate.id)
            total -= candidate.bytes
        }
        return out
    }
}
