import Foundation

public struct SyncObjectMetadata: Sendable, Equatable {
    public let key: String
    public let etag: String?
    public let size: Int64?

    public init(key: String, etag: String? = nil, size: Int64? = nil) {
        self.key = key
        self.etag = etag
        self.size = size
    }
}

public struct SyncObject: Sendable, Equatable {
    public let data: Data
    public let etag: String?

    public init(data: Data, etag: String?) {
        self.data = data
        self.etag = etag
    }
}

public protocol SyncObjectStore: Sendable {
    func validateAccess() async throws
    func list(prefix: String) async throws -> [SyncObjectMetadata]
    func read(key: String) async throws -> SyncObject
    func write(key: String, data: Data) async throws
    func delete(key: String) async throws
}

public enum SyncObjectStoreError: Error, Equatable, LocalizedError {
    case invalidConfiguration(String)
    case notFound(String)
    case httpStatus(Int, String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let reason): return reason
        case .notFound(let key): return "Remote object not found: \(key)"
        case .httpStatus(let status, let detail): return "Remote storage returned HTTP \(status): \(detail)"
        case .invalidResponse(let detail): return "Invalid remote storage response: \(detail)"
        }
    }
}

public protocol SyncHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionSyncHTTPClient: SyncHTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SyncObjectStoreError.invalidResponse("non-HTTP response")
        }
        return (data, http)
    }
}

func responseDetail(_ data: Data) -> String {
    let text = String(decoding: data.prefix(512), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? "no response body" : text
}
