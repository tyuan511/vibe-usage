import Foundation
import Network

/// Errors surfaced by ``LoopbackCallbackServer``.
public enum LoopbackCallbackError: Error, Equatable, LocalizedError {
    case portInUse(Int)
    case timedOut
    case listenerFailed(String)
    case invalidCallback

    public var errorDescription: String? {
        switch self {
        case .portInUse(let port):
            return "Port \(port) is already in use"
        case .timedOut:
            return "Timed out waiting for browser authorization"
        case .listenerFailed(let reason):
            return "Failed to start local callback server: \(reason)"
        case .invalidCallback:
            return "Received an invalid callback request"
        }
    }
}

/// The parsed result of a single OAuth redirect callback.
public struct LoopbackCallbackResult: Sendable, Equatable {
    public let code: String
    public let state: String?

    public init(code: String, state: String?) {
        self.code = code
        self.state = state
    }
}

/// Minimal single-shot HTTP server used only for the Codex loopback OAuth
/// redirect: binds `127.0.0.1:port`, waits for exactly one GET request to
/// `path`, extracts `code`/`state` from the query string, replies with a
/// small bilingual HTML page, then tears the listener down.
///
/// Built on `Network.framework` (`NWListener`) rather than a full HTTP
/// server library since the only requirement is parsing a single GET
/// request line's query string.
public final class LoopbackCallbackServer: @unchecked Sendable {
    private let port: Int
    private let path: String
    private let timeout: TimeInterval

    public init(port: Int, path: String, timeout: TimeInterval = 120) {
        self.port = port
        self.path = path
        self.timeout = timeout
    }

    /// Starts listening and suspends until a matching callback request
    /// arrives, the timeout elapses, or the listener fails to bind.
    public func awaitCallback() async throws -> LoopbackCallbackResult {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw LoopbackCallbackError.listenerFailed("invalid port \(port)")
        }

        let listener: NWListener
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = false
            listener = try NWListener(using: parameters, on: nwPort)
        } catch {
            throw LoopbackCallbackError.listenerFailed(error.localizedDescription)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let box = ContinuationBox(continuation: continuation)
            let queue = DispatchQueue(label: "com.vibeusage.oauth.loopback")

            let timeoutWorkItem = DispatchWorkItem {
                if box.finish() {
                    listener.cancel()
                    continuation.resume(throwing: LoopbackCallbackError.timedOut)
                }
            }
            queue.asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)

            listener.stateUpdateHandler = { state in
                switch state {
                case .failed(let error):
                    if box.finish() {
                        timeoutWorkItem.cancel()
                        listener.cancel()
                        if case .posix(let code) = error, code == .EADDRINUSE {
                            continuation.resume(throwing: LoopbackCallbackError.portInUse(self.port))
                        } else {
                            continuation.resume(throwing: LoopbackCallbackError.listenerFailed(error.localizedDescription))
                        }
                    }
                default:
                    break
                }
            }

            listener.newConnectionHandler = { connection in
                self.handle(connection: connection, on: queue) { result in
                    guard box.finish() else { return }
                    timeoutWorkItem.cancel()
                    listener.cancel()
                    switch result {
                    case .success(let callbackResult):
                        continuation.resume(returning: callbackResult)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            }

            listener.start(queue: queue)
        }
    }

    private func handle(
        connection: NWConnection,
        on queue: DispatchQueue,
        completion: @escaping (Result<LoopbackCallbackResult, Error>) -> Void
    ) {
        connection.start(queue: queue)
        receiveRequestLine(connection: connection, buffer: Data()) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                connection.cancel()
                completion(.failure(error))
            case .success(let requestData):
                guard let callback = self.parseRequest(requestData) else {
                    self.respond(connection: connection, ok: false)
                    completion(.failure(LoopbackCallbackError.invalidCallback))
                    return
                }
                self.respond(connection: connection, ok: true)
                completion(.success(callback))
            }
        }
    }

    private func receiveRequestLine(
        connection: NWConnection,
        buffer: Data,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, isComplete, error in
            if let error {
                completion(.failure(error))
                return
            }
            var accumulated = buffer
            if let data {
                accumulated.append(data)
            }
            // A GET request's headers are terminated by a blank line; we only
            // need the request line itself, which arrives first.
            if accumulated.range(of: Data("\r\n".utf8)) != nil || isComplete || data == nil {
                completion(.success(accumulated))
            } else {
                self.receiveRequestLine(connection: connection, buffer: accumulated, completion: completion)
            }
        }
    }

    private func parseRequest(_ data: Data) -> LoopbackCallbackResult? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        guard let requestLine = text.split(separator: "\r\n").first else { return nil }
        // "GET /auth/callback?code=X&state=Y HTTP/1.1"
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let target = String(parts[1])
        guard let components = URLComponents(string: target) else { return nil }
        guard components.path == path else { return nil }
        let items = components.queryItems ?? []
        guard let code = items.first(where: { $0.name == "code" })?.value else { return nil }
        let state = items.first(where: { $0.name == "state" })?.value
        return LoopbackCallbackResult(code: code, state: state)
    }

    private func respond(connection: NWConnection, ok: Bool) {
        let title = ok
            ? "VibeUsage"
            : "VibeUsage"
        let body = ok
            ? "<h1>连接成功 / Connected</h1><p>你可以关闭此页面 / You can close this tab.</p>"
            : "<h1>连接失败 / Connection failed</h1><p>请返回 VibeUsage 重试 / Please return to VibeUsage and try again.</p>"
        let html = """
        <html><head><meta charset="utf-8"><title>\(title)</title></head>
        <body style="font-family: -apple-system, sans-serif; text-align: center; padding-top: 80px;">\(body)</body></html>
        """
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// Guards against the continuation being resumed twice (e.g. a timeout
    /// firing at the same moment a callback arrives).
    private final class ContinuationBox: @unchecked Sendable {
        private var finished = false
        private let lock = NSLock()

        init<T, E: Error>(continuation: CheckedContinuation<T, E>) {}

        /// Returns `true` the first time it's called, `false` on any
        /// subsequent call.
        func finish() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return false }
            finished = true
            return true
        }
    }
}
