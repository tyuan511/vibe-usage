import SwiftUI
import VibeUsageUI
import XCTest
@testable import VibeUsageApp

@MainActor
final class MenuBarStatusLabelTests: XCTestCase {
    func testTwoLineMetricsRemainCompactWithIconOnlyLabelStyle() {
        let iconSize = fittingSize(metrics: nil)
        let metricSize = fittingSize(metrics: .init(tokens: "12.3K", spend: "$47.6"))

        XCTAssertGreaterThan(metricSize.width, iconSize.width + 20)
        XCTAssertLessThanOrEqual(metricSize.height, 22)
    }

    func testStatusImageContainsPixelsForBothMetrics() throws {
        let baseline = try renderedStatusImage(tokens: "63.3M", spend: "$47.6")
        let changedTokens = try renderedStatusImage(tokens: "88.8M", spend: "$47.6")
        let changedSpend = try renderedStatusImage(tokens: "63.3M", spend: "$88.8")

        XCTAssertNotEqual(baseline, changedTokens)
        XCTAssertNotEqual(baseline, changedSpend)
    }

    private func fittingSize(metrics: MenuBarMetricValues?) -> CGSize {
        let view = MenuBarStatusLabel(metrics: metrics)
            .labelStyle(.iconOnly)
            .fixedSize()
        return NSHostingView(rootView: view).fittingSize
    }

    private func renderedStatusImage(tokens: String, spend: String) throws -> Data {
        let image = MenuBarStatusImageRenderer.image(
            for: .init(tokens: tokens, spend: spend)
        )
        XCTAssertLessThanOrEqual(image.size.height, NSStatusBar.system.thickness)
        return try XCTUnwrap(image.tiffRepresentation)
    }
}
