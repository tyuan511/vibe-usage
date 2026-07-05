import Foundation

/// Minimal untyped JSON value used to walk upstream quota payloads whose
/// exact field names are not documented. Both Claude's `/api/oauth/usage`
/// and Codex's `/backend-api/wham/usage` responses are decoded into this
/// generic shape first, then windows are pulled out via
/// ``QuotaWindowExtractor`` — see the module-level doc comment there for why
/// this indirection exists.
indirect enum QuotaJSONValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: QuotaJSONValue])
    case array([QuotaJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: QuotaJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([QuotaJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    var objectValue: [String: QuotaJSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        switch self {
        case .number(let value): value
        case .string(let value): Double(value)
        default: nil
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

/// Centralizes the tolerant/defensive field extraction for a single
/// rate-limit window's utilization + reset time, since neither Claude's nor
/// Codex's usage endpoint response schema is documented anywhere public.
/// Every "try this field name" guess lives here so a single correction (once
/// a real payload is captured) fixes both providers.
enum QuotaWindowExtractor {
    /// Tries, in order:
    /// 1. A 0...100 percent field. Claude's `utilization` is a percent (e.g.
    ///    `60.0` for 60% — confirmed against the live `/api/oauth/usage`
    ///    response), as are `used_percent`/`percent`/etc.
    /// 2. A direct 0...1 fraction field (`used_fraction`, `usedFraction`).
    /// 3. A `used` + `limit` (or `max`/`capacity`) ratio.
    static func usedFraction(from object: [String: QuotaJSONValue]) -> Double? {
        // Percent-scaled fields (0...100). `utilization` is Claude's; the rest
        // cover Codex / other spellings.
        for key in ["utilization", "used_percent", "usedPercent", "percent_used", "percentUsed", "percent"] {
            if let percent = object[key]?.doubleValue {
                return clamp(percent / 100)
            }
        }
        // Explicit 0...1 fraction fields.
        for key in ["used_fraction", "usedFraction"] {
            if let fraction = object[key]?.doubleValue {
                return clamp(fraction)
            }
        }
        let usedKeys = ["used", "used_tokens", "usedTokens", "current_usage", "currentUsage"]
        let limitKeys = ["limit", "max", "capacity", "total", "quota"]
        if let used = firstDouble(object, keys: usedKeys),
           let limit = firstDouble(object, keys: limitKeys),
           limit > 0 {
            return clamp(used / limit)
        }
        return nil
    }

    /// Tries, in order:
    /// 1. An absolute ISO8601 timestamp (`resets_at`, `reset_at`, `resetsAt`,
    ///    `reset_time`, `resetTime`).
    /// 2. A relative seconds-until-reset value (`resets_in_seconds`,
    ///    `reset_after_seconds`, `resetsInSeconds`, `seconds_until_reset`),
    ///    resolved against `now`.
    static func resetsAt(from object: [String: QuotaJSONValue], now: Date) -> Date? {
        for key in ["resets_at", "reset_at", "resetsAt", "reset_time", "resetTime"] {
            if let raw = object[key]?.stringValue, let date = parseISO8601(raw) {
                return date
            }
            // Some payloads may report these as unix epoch seconds instead of ISO strings.
            if let epoch = object[key]?.doubleValue, epoch > 0 {
                return Date(timeIntervalSince1970: epoch)
            }
        }
        for key in ["resets_in_seconds", "reset_after_seconds", "resetsInSeconds", "seconds_until_reset", "secondsUntilReset"] {
            if let seconds = object[key]?.doubleValue {
                return now.addingTimeInterval(seconds)
            }
        }
        return nil
    }

    private static func firstDouble(_ object: [String: QuotaJSONValue], keys: [String]) -> Double? {
        for key in keys {
            if let value = object[key]?.doubleValue {
                return value
            }
        }
        return nil
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private static func parseISO8601(_ string: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: string) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: string) {
            return date
        }
        // Claude's `resets_at` carries microsecond precision (6 fractional
        // digits, e.g. `...59.875437+00:00`), which `ISO8601DateFormatter`'s
        // `.withFractionalSeconds` (millisecond-only) rejects. Strip the
        // fractional part and retry — sub-second precision is irrelevant for a
        // reset countdown.
        let stripped = string.replacingOccurrences(
            of: #"\.\d+"#,
            with: "",
            options: .regularExpression
        )
        return plain.date(from: stripped)
    }
}
