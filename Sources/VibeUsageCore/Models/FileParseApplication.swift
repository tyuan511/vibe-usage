import Foundation

/// One parsed file and the filesystem metadata captured for the same scan.
/// Stores can persist several applications in one transaction while retaining
/// the existing per-file checkpoint semantics.
public struct FileParseApplication: Sendable {
    public let result: ParseResult
    public let file: DiscoveredFile
    public let fileSize: Int64
    public let fileModifiedAt: Date?

    public init(
        result: ParseResult,
        file: DiscoveredFile,
        fileSize: Int64,
        fileModifiedAt: Date?
    ) {
        self.result = result
        self.file = file
        self.fileSize = fileSize
        self.fileModifiedAt = fileModifiedAt
    }
}
