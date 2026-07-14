import AppKit
import SwiftUI
import Testing
import VibeUsageAggregation
import VibeUsageCore
@testable import VibeUsageUI
import VibeUsageQuota

@Suite struct MenuBarImageExporterTests {
    @MainActor
    @Test func offscreenExportUsesContentBoundsAndOpaqueBackground() throws {
        let size = CGSize(width: 160, height: 90)
        let scale: CGFloat = 2
        let data = MenuBarImageExporter.renderPNGData(
            colorScheme: .light,
            scale: scale
        ) {
            Color.clear.frame(width: size.width, height: size.height)
        }
        let bitmap = data.flatMap(NSBitmapImageRep.init(data:))
        let edgePoints = [
            NSPoint(x: 1, y: size.height / 2),
            NSPoint(x: size.width - 2, y: size.height / 2),
            NSPoint(x: size.width / 2, y: 1),
            NSPoint(x: size.width / 2, y: size.height - 2),
        ]
        let edgeColors = edgePoints.compactMap { point in
            bitmap?.colorAt(
                x: Int(point.x * scale),
                y: Int(point.y * scale)
            )?.usingColorSpace(.deviceRGB)
        }

        #expect(bitmap?.pixelsWide == Int(size.width * scale))
        #expect(bitmap?.pixelsHigh == Int(size.height * scale))
        #expect(edgeColors.count == edgePoints.count)
        #expect(edgeColors.allSatisfy { $0.brightnessComponent > 0.95 })
        #expect(edgeColors.allSatisfy { $0.alphaComponent == 1 })
    }

    @MainActor
    @Test func offscreenExportUsesDeterministicCardStyle() throws {
        let data = MenuBarImageExporter.renderPNGData(
            colorScheme: .light,
            scale: 2
        ) {
            Color.clear
                .frame(width: 100, height: 60)
                .menuCard(in: RoundedRectangle(cornerRadius: 12))
        }
        let bitmap = try #require(data.flatMap(NSBitmapImageRep.init(data:)))
        let center = try #require(
            bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?
                .usingColorSpace(.deviceRGB)
        )

        #expect(center.brightnessComponent > 0.9)
        #expect(center.brightnessComponent < 0.98)
        #expect(center.alphaComponent == 1)
    }

    @MainActor
    @Test func offscreenExportDoesNotContainUnsupportedControlPlaceholders() throws {
        let data = MenuBarImageExporter.renderPNGData(
            colorScheme: .light,
            scale: 2
        ) {
            QuotaWindowBar(
                window: QuotaWindow(
                    id: "five-hour",
                    label: "5 小时额度",
                    usedFraction: 0.4,
                    usedPercentText: "40%",
                    resetsAt: nil,
                    resetCountdownText: "3 小时后重置"
                )
            )
            .frame(width: 240)
            .padding(12)
        }
        let bitmap = try #require(data.flatMap(NSBitmapImageRep.init(data:)))

        #expect(!containsPlaceholderColor(in: bitmap))
    }

    @MainActor
    @Test func offscreenExportBuildsAFreshRootInTheExportEnvironment() async throws {
        var exportedData: Data?
        var isRenderingExport = false
        let harness = RootEnvironmentHarness { resolvedView in
            guard exportedData == nil, !isRenderingExport else { return }
            isRenderingExport = true
            exportedData = MenuBarImageExporter.renderPNGData(
                colorScheme: .light,
                scale: 2
            ) {
                resolvedView.freshCopy
            }
            isRenderingExport = false
        }
        let hostingView = NSHostingView(rootView: harness)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 40, height: 40),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        for _ in 0..<20 where exportedData == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        let bitmap = try #require(exportedData.flatMap(NSBitmapImageRep.init(data:)))
        let center = try #require(
            bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?
                .usingColorSpace(.deviceRGB)
        )
        #expect(center.greenComponent > 0.8)
        #expect(center.redComponent < 0.3)
    }

    @MainActor
    @Test func exportModeOmitsTheModelFilterControl() throws {
        let model = ModelUsageSummary(
            modelFamily: "gpt-5.6-sol",
            sourceID: .codexCLI,
            tokens: TokenCounts(input: 100, output: 20),
            costUSD: 1,
            eventCount: 1
        )
        let exportWithFilterOptions = renderMenuBar(availableModels: [model], displayedModel: model)
        let exportWithoutFilterOptions = renderMenuBar(availableModels: [], displayedModel: model)

        #expect(exportWithFilterOptions == exportWithoutFilterOptions)
    }

    private func containsPlaceholderColor(in bitmap: NSBitmapImageRep) -> Bool {
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                let isYellow = color.redComponent > 0.9
                    && color.greenComponent > 0.65
                    && color.blueComponent < 0.25
                let isMagenta = color.redComponent > 0.9
                    && color.greenComponent < 0.5
                    && color.blueComponent > 0.25
                if isYellow || isMagenta {
                    return true
                }
            }
        }
        return false
    }

    @MainActor
    private func renderMenuBar(
        availableModels: [ModelUsageSummary],
        displayedModel: ModelUsageSummary
    ) -> Data? {
        let snapshot = UsageDashboardSnapshot(
            generatedAt: Date(timeIntervalSince1970: 0),
            rangeStartDay: "2026-07-14",
            rangeEndDay: "2026-07-14",
            totals: UsageTotals(
                tokens: displayedModel.tokens,
                costUSD: displayedModel.costUSD,
                eventCount: 1
            ),
            sources: [],
            daily: [],
            activity: [],
            models: [displayedModel],
            availableModels: availableModels,
            discoveredSources: []
        )
        let view = MenuBarUsageView(
            snapshot: snapshot,
            isRefreshing: false,
            lastError: nil,
            quota: .empty,
            selectedDateRange: .constant(.today),
            selectedModelFilter: .constant([]),
            hiddenQuotaSourceIDs: [],
            onRefresh: {},
            onFilterChange: {},
            onOpenSettings: {},
            onQuit: {}
        )
        .fixedSize(horizontal: false, vertical: true)

        return MenuBarImageExporter.renderPNGData(
            colorScheme: .light,
            scale: 1
        ) {
            view
        }
    }
}

private struct RootEnvironmentHarness: View {
    @Environment(\.menuBarExportMode) private var isExporting
    let onResolve: (RootEnvironmentHarness) -> Void

    var freshCopy: RootEnvironmentHarness {
        RootEnvironmentHarness(onResolve: { _ in })
    }

    var body: some View {
        Rectangle()
            .fill(isExporting ? Color.green : Color.yellow)
            .frame(width: 40, height: 40)
            .onAppear { onResolve(self) }
    }
}
