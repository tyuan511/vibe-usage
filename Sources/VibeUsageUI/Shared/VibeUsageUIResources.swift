import Foundation

enum VibeUsageUIResources {
    static var bundle: Bundle {
        if let resourceURL = Bundle.main.resourceURL?.appendingPathComponent("VibeUsage_VibeUsageUI.bundle"),
           let bundle = Bundle(url: resourceURL) {
            return bundle
        }
        return .module
    }
}
