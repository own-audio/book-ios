import Foundation

/// `POST /uploads`: a signed link to put one file straight into storage, then named in
/// `POST /books`.
public struct UploadLink: Decodable, Sendable, Equatable {
    public let uploadId: String
    public let url: URL
    public let method: String
    /// Part of the signature: the PUT sends exactly these.
    public let headers: [String: String]
    public let expiresAt: Date
}

/// `POST /books`: a book from uploaded files, in the order given.
public struct NewBook: Encodable, Sendable, Equatable {
    public struct File: Encodable, Sendable, Equatable {
        public let uploadId: String
        /// Sets the files' order and names them; `01 - Chapter one.mp3`.
        public let relativePath: String?
        public let title: String?

        public init(uploadId: String, relativePath: String?, title: String?) {
            self.uploadId = uploadId
            self.relativePath = relativePath
            self.title = title
        }
    }

    public var title: String?
    /// Several with `;` between them.
    public var author: String?
    public var narrator: String?
    public var description: String?
    /// `private` (the default) or `family`.
    public var visibility: String?
    public var coverUploadId: String?
    public var files: [File]

    public init(title: String?, author: String?, narrator: String?, description: String? = nil, visibility: String? = nil, coverUploadId: String? = nil, files: [File]) {
        self.title = title
        self.author = author
        self.narrator = narrator
        self.description = description
        self.visibility = visibility
        self.coverUploadId = coverUploadId
        self.files = files
    }
}

extension OwnAudioClient {
    /// A link for one file; `sizeBytes` must be exact, the server refuses anything else.
    /// `kind` is `book_file` or `book_cover`.
    public func createUpload(kind: String, filename: String, contentType: String, sizeBytes: Int64) async throws -> UploadLink {
        struct Body: Encodable { let kind: String; let filename: String; let contentType: String; let sizeBytes: Int64 }
        return try await call("POST", "uploads", body: Body(kind: kind, filename: filename, contentType: contentType, sizeBytes: sizeBytes))
    }

    /// The book once every file is in storage. `idempotencyKey` makes a retry answer the same
    /// book rather than make a second one.
    public func createBook(_ book: NewBook, idempotencyKey: String) async throws -> Book {
        try await call("POST", "books", body: book, idempotencyKey: idempotencyKey)
    }
}
