import Foundation

/// Thin seam over `URLSession` so quota providers can be tested with canned
/// responses instead of live network calls.
public protocol HTTPFetching: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Production implementation backed by `URLSession`.
public struct URLSessionHTTPFetcher: HTTPFetching {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, httpResponse)
    }
}
