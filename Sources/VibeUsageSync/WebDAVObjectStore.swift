import Foundation

public struct WebDAVConfiguration: Sendable, Equatable {
    public let baseURL: URL
    public let username: String
    public let password: String

    public init(baseURL: URL, username: String, password: String) {
        self.baseURL = baseURL
        self.username = username
        self.password = password
    }
}

public struct WebDAVObjectStore: SyncObjectStore {
    private let configuration: WebDAVConfiguration
    private let httpClient: any SyncHTTPClient
    private let collectionCache = WebDAVCollectionCache()

    public init(
        configuration: WebDAVConfiguration,
        httpClient: any SyncHTTPClient = URLSessionSyncHTTPClient()
    ) throws {
        guard configuration.baseURL.scheme?.lowercased() == "https" else {
            throw SyncObjectStoreError.invalidConfiguration("WebDAV requires an HTTPS URL.")
        }
        guard !configuration.username.isEmpty, !configuration.password.isEmpty else {
            throw SyncObjectStoreError.invalidConfiguration("WebDAV username and password are required.")
        }
        self.configuration = configuration
        self.httpClient = httpClient
    }

    public func validateAccess() async throws {
        let key = "\(SyncNamespace.root)/.probe-\(UUID().uuidString.lowercased())"
        let payload = Data("vibeusage-sync-probe".utf8)
        try await write(key: key, data: payload)
        do {
            let roundTrip = try await read(key: key)
            guard roundTrip.data == payload else {
                throw SyncObjectStoreError.invalidResponse("WebDAV probe content did not round-trip")
            }
            try await delete(key: key)
        } catch {
            try? await delete(key: key)
            throw error
        }
    }

    public func list(prefix: String) async throws -> [SyncObjectMetadata] {
        var pendingCollections = [prefix]
        var visitedCollections = Set<String>()
        var objects: [SyncObjectMetadata] = []
        while let collection = pendingCollections.popLast() {
            guard visitedCollections.insert(collection).inserted else { continue }
            let entries = try await listCollection(collection)
            for entry in entries where entry.metadata.key != collection {
                guard entry.metadata.key.hasPrefix(prefix) else { continue }
                if entry.isCollection {
                    pendingCollections.append(entry.metadata.key)
                } else {
                    objects.append(entry.metadata)
                }
            }
        }
        return objects.sorted { $0.key < $1.key }
    }

    private func listCollection(_ key: String) async throws -> [WebDAVListEntry] {
        let url = objectURL(for: key)
        var request = authenticatedRequest(url: url, method: "PROPFIND")
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("""
            <?xml version="1.0" encoding="utf-8" ?>
            <d:propfind xmlns:d="DAV:"><d:prop><d:getetag/><d:getcontentlength/><d:resourcetype/></d:prop></d:propfind>
            """.utf8)
        let (data, response) = try await httpClient.data(for: request)
        guard response.statusCode == 207 else {
            if response.statusCode == 404 { return [] }
            throw SyncObjectStoreError.httpStatus(response.statusCode, responseDetail(data))
        }
        return try WebDAVListParser.parse(data: data, baseURL: configuration.baseURL)
    }

    public func read(key: String) async throws -> SyncObject {
        let request = authenticatedRequest(url: objectURL(for: key), method: "GET")
        let (data, response) = try await httpClient.data(for: request)
        guard response.statusCode == 200 else {
            if response.statusCode == 404 { throw SyncObjectStoreError.notFound(key) }
            throw SyncObjectStoreError.httpStatus(response.statusCode, responseDetail(data))
        }
        return SyncObject(data: data, etag: response.value(forHTTPHeaderField: "ETag"))
    }

    public func write(key: String, data: Data) async throws {
        try await ensureParentCollections(for: key)
        var request = authenticatedRequest(url: objectURL(for: key), method: "PUT")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (responseData, response) = try await httpClient.data(for: request)
        guard [200, 201, 204].contains(response.statusCode) else {
            throw SyncObjectStoreError.httpStatus(response.statusCode, responseDetail(responseData))
        }
    }

    public func delete(key: String) async throws {
        let request = authenticatedRequest(url: objectURL(for: key), method: "DELETE")
        let (data, response) = try await httpClient.data(for: request)
        guard [200, 204, 404].contains(response.statusCode) else {
            throw SyncObjectStoreError.httpStatus(response.statusCode, responseDetail(data))
        }
    }

    private func ensureParentCollections(for key: String) async throws {
        let parts = key.split(separator: "/").map(String.init)
        guard parts.count > 1 else { return }
        var parent = ""
        for part in parts.dropLast() {
            parent = parent.isEmpty ? part : "\(parent)/\(part)"
            guard collectionCache.reserve(parent) else { continue }
            let request = authenticatedRequest(url: objectURL(for: parent), method: "MKCOL")
            do {
                let (data, response) = try await httpClient.data(for: request)
                guard [200, 201, 204, 301, 405].contains(response.statusCode) else {
                    collectionCache.remove(parent)
                    throw SyncObjectStoreError.httpStatus(response.statusCode, responseDetail(data))
                }
            } catch {
                collectionCache.remove(parent)
                throw error
            }
        }
    }

    private func authenticatedRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        let value = Data("\(configuration.username):\(configuration.password)".utf8).base64EncodedString()
        request.setValue("Basic \(value)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func objectURL(for key: String) -> URL {
        key.split(separator: "/").reduce(configuration.baseURL) { url, component in
            url.appendingPathComponent(String(component), isDirectory: false)
        }
    }
}

private final class WebDAVCollectionCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values = Set<String>()

    func reserve(_ value: String) -> Bool {
        lock.withLock { values.insert(value).inserted }
    }

    func remove(_ value: String) {
        lock.withLock { _ = values.remove(value) }
    }
}

private struct WebDAVListEntry {
    let metadata: SyncObjectMetadata
    let isCollection: Bool
}

private final class WebDAVListParser: NSObject, XMLParserDelegate {
    private var currentElement = ""
    private var currentText = ""
    private var currentHref: String?
    private var currentETag: String?
    private var currentSize: Int64?
    private var isCollection = false
    private var entries: [(href: String, etag: String?, size: Int64?, isCollection: Bool)] = []

    static func parse(data: Data, baseURL: URL) throws -> [WebDAVListEntry] {
        let delegate = WebDAVListParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw SyncObjectStoreError.invalidResponse("malformed WebDAV PROPFIND XML")
        }
        let basePath = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return delegate.entries.compactMap { entry in
            let path = URL(string: entry.href)?.path.removingPercentEncoding ?? entry.href
            var relative = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !basePath.isEmpty, relative.hasPrefix(basePath + "/") {
                relative.removeFirst(basePath.count + 1)
            }
            guard !relative.isEmpty else { return nil }
            return WebDAVListEntry(
                metadata: SyncObjectMetadata(key: relative, etag: entry.etag, size: entry.size),
                isCollection: entry.isCollection
            )
        }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName.lowercased()
        currentText = ""
        if currentElement.hasSuffix("response") {
            currentHref = nil
            currentETag = nil
            currentSize = nil
            isCollection = false
        }
        if currentElement.hasSuffix("collection") { isCollection = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        let name = elementName.lowercased()
        let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasSuffix("href") { currentHref = value }
        if name.hasSuffix("getetag") { currentETag = value.isEmpty ? nil : value }
        if name.hasSuffix("getcontentlength") { currentSize = Int64(value) }
        if name.hasSuffix("response"), let currentHref, !isCollection {
            entries.append((currentHref, currentETag, currentSize, false))
        } else if name.hasSuffix("response"), let currentHref {
            entries.append((currentHref, currentETag, currentSize, true))
        }
        currentText = ""
    }
}
