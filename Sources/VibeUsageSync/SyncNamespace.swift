import Foundation

public enum SyncNamespace {
    public static let root = "vibeusage/sync/v1"

    public static func devicePrefix(deviceID: String) -> String {
        "\(root)/devices/\(deviceID)"
    }

    public static func profileKey(deviceID: String) -> String {
        "\(devicePrefix(deviceID: deviceID))/profile.json"
    }

    public static func indexKey(deviceID: String) -> String {
        "\(devicePrefix(deviceID: deviceID))/index.json"
    }

    public static func dayKey(deviceID: String, day: String) -> String {
        "\(devicePrefix(deviceID: deviceID))/days/\(day).json"
    }

    static func isValidDeviceID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128 && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-"
        }
    }

    static func isValidDay(_ value: String) -> Bool {
        guard value.count == 10 else { return false }
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else {
            return false
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
            return false
        }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return components.year == year && components.month == month && components.day == day
    }
}
