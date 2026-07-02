import Foundation

public enum VibeUsageStrings {
    public static var isChinesePreferred: Bool {
        let language = Locale.preferredLanguages.first?.lowercased() ?? ""
        return language == "zh" || language.hasPrefix("zh-") || language.hasPrefix("zh_")
    }

    public static func text(zh: String, en: String) -> String {
        isChinesePreferred ? zh : en
    }
}
