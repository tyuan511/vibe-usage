import Foundation
import VibeUsageCore

enum UIStrings {
    static func text(zh: String, en: String) -> String {
        VibeUsageStrings.text(zh: zh, en: en)
    }

    static let scanning = text(zh: "扫描中", en: "Scanning")
    static let refresh = text(zh: "刷新", en: "Refresh")
    static let checkForUpdates = text(zh: "检查更新", en: "Check for Updates")
    static let spend = text(zh: "花费", en: "Spend")
    static let cost = text(zh: "费用", en: "Cost")
    static let tokens = text(zh: "Tokens", en: "Tokens")
    static let events = text(zh: "事件", en: "Events")
    static let input = text(zh: "输入", en: "Input")
    static let output = text(zh: "输出", en: "Output")
    static let cacheRead = text(zh: "缓存", en: "Cache Read")
    static let agents = text(zh: "Agents", en: "Agents")
    static let models = text(zh: "模型", en: "Models")
    static let done = text(zh: "完成", en: "Done")
    static let estimatedCost = text(zh: "估算", en: "Est.")
    static let allModels = text(zh: "全部模型", en: "All Models")
    static let lessActivity = text(zh: "少", en: "Less")
    static let moreActivity = text(zh: "多", en: "More")

    static func updated(_ date: Date) -> String {
        text(
            zh: "更新于 \(date.formatted(date: .omitted, time: .shortened))",
            en: "Updated \(date.formatted(date: .omitted, time: .shortened))"
        )
    }

    static func activityDetail(day: String, tokens: String, cost: String) -> String {
        text(zh: "\(day): \(tokens) tokens, \(cost)", en: "\(day): \(tokens) tokens, \(cost)")
    }

    static func modelTokenLine(sourceID: String, tokens: String) -> String {
        text(zh: "\(sourceID) · \(tokens) tokens", en: "\(sourceID) · \(tokens) tokens")
    }

    static func costLabel(_ amount: String, estimated: Bool) -> String {
        estimated ? text(zh: "\(amount) (估算)", en: "\(amount) (est.)") : amount
    }

    static func percentage(_ ratio: Double) -> String {
        let percent = Int((ratio * 100).rounded())
        return percent == 0 && ratio > 0 ? "<1%" : "\(percent)%"
    }
}
