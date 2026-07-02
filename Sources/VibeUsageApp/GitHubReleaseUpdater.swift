import AppKit
import Foundation
import VibeUsageCore

enum GitHubReleaseUpdater {
    private static let owner = "tyuan511"
    private static let repo = "vibe-usage"
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration)
    }()

    static func checkForUpdates() async {
        guard let current = AppVersion.current,
              let release = try? await latestRelease(),
              let latest = AppVersion(release.tagName),
              latest > current else {
            return
        }

        await presentUpdatePrompt(release: release, current: current, latest: latest)
    }

    private static func latestRelease() async throws -> GitHubRelease {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("VibeUsage", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    @MainActor
    private static func presentUpdatePrompt(
        release: GitHubRelease,
        current: AppVersion,
        latest: AppVersion
    ) {
        let downloadURL = release.dmgAssetURL ?? release.htmlURL
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = VibeUsageStrings.text(zh: "发现新版本", en: "Update Available")
        alert.informativeText = VibeUsageStrings.text(
            zh: "VibeUsage \(latest.description) 已发布，当前版本是 \(current.description)。",
            en: "VibeUsage \(latest.description) is available. You are currently using \(current.description)."
        )
        alert.addButton(withTitle: VibeUsageStrings.text(zh: "下载更新", en: "Download"))
        alert.addButton(withTitle: VibeUsageStrings.text(zh: "稍后", en: "Later"))

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NSWorkspace.shared.open(downloadURL)
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: URL
    let assets: [GitHubReleaseAsset]

    var dmgAssetURL: URL? {
        assets.first { $0.name.lowercased().hasSuffix(".dmg") }?.downloadURL
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets
    }
}

private struct GitHubReleaseAsset: Decodable {
    let name: String
    let downloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name
        case downloadURL = "browser_download_url"
    }
}

private struct AppVersion: Comparable, CustomStringConvertible {
    let components: [Int]

    static var current: AppVersion? {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return nil
        }
        return AppVersion(version)
    }

    init?(_ rawValue: String) {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingPrefix("v")
            .split(separator: "-", maxSplits: 1)
            .first
            .map(String.init) ?? ""
        let parsed = normalized
            .split(separator: ".")
            .map { component in
                component.prefix { $0.isNumber }
            }
            .compactMap { Int($0) }

        guard !parsed.isEmpty else { return nil }
        self.components = parsed
    }

    var description: String {
        components.map(String.init).joined(separator: ".")
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right {
                return left < right
            }
        }
        return false
    }
}

private extension String {
    func trimmingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }
}
