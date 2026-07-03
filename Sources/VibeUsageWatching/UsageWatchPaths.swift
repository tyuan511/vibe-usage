import Foundation
import VibeUsageCore

enum UsageWatchPaths {
    static func directories(from registry: AdapterRegistry) -> [String] {
        var paths = Set<String>()
        let fileManager = FileManager.default

        for adapter in registry.allAdapters {
            for url in adapter.discoverRootDirectories() {
                var isDirectory: ObjCBool = false
                let path = url.standardizedFileURL.path
                guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    continue
                }
                paths.insert(path)
            }
        }

        return paths.sorted()
    }
}
