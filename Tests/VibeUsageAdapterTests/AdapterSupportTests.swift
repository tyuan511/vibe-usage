import Foundation
import XCTest
@testable import VibeUsageAdapter

final class AdapterSupportTests: XCTestCase {
    func testDateParserAcceptsSupportedISO8601Variants() throws {
        let plain = try XCTUnwrap(Date.vibeUsageParse("2026-07-20T08:47:23Z"))
        let fractional = try XCTUnwrap(Date.vibeUsageParse("2026-07-20T08:47:23.123456Z"))
        let offset = try XCTUnwrap(Date.vibeUsageParse("2026-07-20T16:47:23.123456+08:00"))

        XCTAssertEqual(fractional.timeIntervalSince(plain), 0.123456, accuracy: 0.000_001)
        XCTAssertEqual(offset.timeIntervalSince(fractional), 0, accuracy: 0.000_001)
        XCTAssertNil(Date.vibeUsageParse("not-a-date"))
    }

    func testYYJSONHelpersPreserveDynamicValueConversions() throws {
        let object = try XCTUnwrap(jsonValue(from: #"""
        {
            "integer": 42,
            "numericString": "17",
            "decimal": 1.25,
            "maxInteger": 9223372036854775807,
            "overflowInteger": 9223372036854775808,
            "timestamp": "2026-07-20T08:47:23.123456Z",
            "nested": { "tokens": 9 }
        }
        """#))

        XCTAssertEqual(firstInt(in: object, keys: ["integer"]), 42)
        XCTAssertEqual(firstInt(in: object, keys: ["numericString"]), 17)
        XCTAssertEqual(firstDecimal(in: object, keys: ["decimal"]), Decimal(string: "1.25"))
        XCTAssertEqual(firstString(in: object, keys: ["maxInteger"]), "9223372036854775807")
        XCTAssertEqual(firstInt(in: object, keys: ["maxInteger"]), Int.max)
        XCTAssertNil(firstInt(in: object, keys: ["overflowInteger"]))
        XCTAssertEqual(nestedInt(in: object, path: ["nested", "tokens"]), 9)
        XCTAssertNotNil(firstDate(in: object, keys: ["timestamp"]))
    }
}
