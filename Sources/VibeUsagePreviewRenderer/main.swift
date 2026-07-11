import AppKit
import SwiftUI
import VibeUsageAdapter
import VibeUsageAggregation
import VibeUsageCore
import VibeUsageQuota
import VibeUsageUI

@main
@MainActor
struct VibeUsagePreviewRenderer {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let outputPath = arguments.first(where: { !$0.hasPrefix("--") })
            ?? "docs/usage-share-preview.png"

        try await renderMenuBar(outputPath: outputPath)
    }

    private static func renderMenuBar(outputPath: String) async throws {
        let view = MenuBarUsageView(
            snapshot: makeDashboardSnapshot(),
            isRefreshing: false,
            lastError: nil,
            quota: .empty,
            selectedDateRange: .constant(.last30Days),
            selectedModelFilter: .constant([]),
            hiddenQuotaSourceIDs: [],
            onRefresh: {},
            onFilterChange: {},
            onOpenSettings: {},
            onQuit: {}
        )
        .environment(\.locale, Locale(identifier: "zh_Hans_CN"))
        .fixedSize(horizontal: false, vertical: true)

        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: 388, height: 1_200)
        hostingView.layoutSubtreeIfNeeded()
        let size = NSSize(width: 388, height: hostingView.fittingSize.height)
        hostingView.frame = NSRect(origin: .zero, size: size)

        let effectView = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        hostingView.autoresizingMask = [.width, .height]
        effectView.addSubview(hostingView)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView = effectView
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(100))

        guard let data = await MenuBarImageExporter.renderPNGData(window: window) else {
            throw RenderError.pngEncodingFailed
        }
        window.orderOut(nil)

        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: outputURL)
        print("Wrote \(outputURL.path)")
    }
}

private enum RenderError: Error {
    case pngEncodingFailed
}

// MARK: - Menu bar mock data

private func makeDashboardSnapshot() -> UsageDashboardSnapshot {
    let opencode = OpenCodeUsageAdapter().descriptor
    let codex = CodexCLIAdapter().descriptor
    let claude = ClaudeCodeAdapter().descriptor
    let gemini = GeminiUsageAdapter().descriptor

    let now = dashboardFixedDate()
    let dayCount = 30
    let dailyRows = makeDailyRows(sources: [opencode, codex, claude, gemini], endingAt: now, dayCount: dayCount)

    let sourceSummaries: [SourceUsageSummary] = [
        SourceUsageSummary(
            descriptor: opencode,
            totals: UsageTotals(tokens: TokenCounts(input: 62_000_000, output: 8_200_000, cacheRead: 14_000_000), costUSD: Decimal(string: "8120.84")!, eventCount: 4218)
        ),
        SourceUsageSummary(
            descriptor: codex,
            totals: UsageTotals(tokens: TokenCounts(input: 18_400_000, output: 3_100_000, cacheRead: 5_600_000, reasoning: 1_200_000), costUSD: Decimal(string: "2457.33")!, eventCount: 1876)
        ),
        SourceUsageSummary(
            descriptor: claude,
            totals: UsageTotals(tokens: TokenCounts(input: 340_000, output: 88_000, cacheRead: 120_000), costUSD: Decimal(string: "41.03")!, eventCount: 96)
        ),
        SourceUsageSummary(
            descriptor: gemini,
            totals: UsageTotals(tokens: TokenCounts(input: 2_100, output: 640, cacheRead: 300), costUSD: Decimal(string: "0.19")!, eventCount: 3)
        )
    ]

    // Hero totals must foot to the agent tiles, so derive them from the same
    // source summaries instead of the (independently shaped) daily rows.
    let grand = sourceSummaries.reduce(UsageTotals()) { partial, source in
        UsageTotals(
            tokens: partial.tokens + source.totals.tokens,
            costUSD: partial.costUSD + source.totals.costUSD,
            eventCount: partial.eventCount + source.totals.eventCount
        )
    }

    let models = makeModelRows(opencode: opencode.id, codex: codex.id, claude: claude.id, gemini: gemini.id)

    return UsageDashboardSnapshot(
        generatedAt: now,
        rangeStartDay: dailyRows.map(\.day).min() ?? "2026-06-05",
        rangeEndDay: dailyRows.map(\.day).max() ?? "2026-07-04",
        totals: grand,
        sources: sourceSummaries,
        daily: dailyRows,
        activity: dailyRows,
        models: models,
        availableModels: models,
        discoveredSources: [opencode, codex, claude, gemini]
    )
}

/// Mirrors the source skew above (opencode dominant, codex-cli secondary,
/// claude-code/gemini tiny) but at model granularity, including one model
/// family (`gpt-5-codex`) that appears under two different sources so
/// per-source rows are verified to render distinctly rather than merging.
private func makeModelRows(
    opencode: AgentSourceID,
    codex: AgentSourceID,
    claude: AgentSourceID,
    gemini: AgentSourceID
) -> [ModelUsageSummary] {
    [
        ModelUsageSummary(
            modelFamily: "gpt-5-codex",
            sourceID: opencode,
            tokens: TokenCounts(input: 38_000_000, output: 5_100_000, cacheRead: 8_600_000),
            costUSD: Decimal(string: "4800.00")!,
            eventCount: 2540
        ),
        ModelUsageSummary(
            modelFamily: "claude-sonnet-4",
            sourceID: opencode,
            tokens: TokenCounts(input: 24_000_000, output: 3_100_000, cacheRead: 5_400_000),
            costUSD: Decimal(string: "3320.84")!,
            eventCount: 1678
        ),
        ModelUsageSummary(
            modelFamily: "gpt-5-codex",
            sourceID: codex,
            tokens: TokenCounts(input: 15_800_000, output: 2_600_000, cacheRead: 4_800_000, reasoning: 1_050_000),
            costUSD: Decimal(string: "2100.00")!,
            eventCount: 1520
        ),
        ModelUsageSummary(
            modelFamily: "gpt-5",
            sourceID: codex,
            tokens: TokenCounts(input: 2_600_000, output: 500_000, cacheRead: 800_000, reasoning: 150_000),
            costUSD: Decimal(string: "357.33")!,
            eventCount: 356
        ),
        ModelUsageSummary(
            modelFamily: "claude-sonnet-4",
            sourceID: claude,
            tokens: TokenCounts(input: 340_000, output: 88_000, cacheRead: 120_000),
            costUSD: Decimal(string: "41.03")!,
            eventCount: 96,
            hasEstimatedCost: true
        ),
        ModelUsageSummary(
            modelFamily: "gemini-2.5-pro",
            sourceID: gemini,
            tokens: TokenCounts(input: 2_100, output: 640, cacheRead: 300),
            costUSD: Decimal(string: "0.19")!,
            eventCount: 3
        )
    ]
}

private func makeDailyRows(sources: [AgentSourceDescriptor], endingAt date: Date, dayCount: Int) -> [DailyUsageSummary] {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let start = calendar.date(byAdding: .day, value: -(dayCount - 1), to: calendar.startOfDay(for: date)) ?? date
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd"

    // Weights roughly matching the dominant/secondary/minor/tiny source split.
    let weights: [AgentSourceID: Double] = [
        sources[0].id: 0.72, // opencode, dominant
        sources[1].id: 0.24, // codex-cli
        sources[2].id: 0.038, // claude-code
        sources[3].id: 0.002 // gemini, near-zero
    ]

    var rows: [DailyUsageSummary] = []
    for offset in 0..<dayCount {
        guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
        let dayString = formatter.string(from: day)

        // Lumpy activity: a couple of zero days, a spike near the end, and
        // otherwise gently varying baseline.
        let isZeroDay = offset == 4 || offset == 11
        let isSpike = offset == dayCount - 6
        let baseMultiplier: Double
        if isZeroDay {
            baseMultiplier = 0
        } else if isSpike {
            baseMultiplier = 3.4
        } else {
            baseMultiplier = 0.6 + 0.5 * sin(Double(offset) * 0.7)
        }

        guard baseMultiplier > 0 else { continue }

        let dayTotalCost = 350.0 * baseMultiplier
        for descriptor in sources {
            let weight = weights[descriptor.id] ?? 0
            guard weight > 0 else { continue }
            let cost = dayTotalCost * weight
            guard cost > 0.001 else { continue }
            let tokenScale = cost * 8_000
            rows.append(
                DailyUsageSummary(
                    day: dayString,
                    sourceID: descriptor.id,
                    tokens: TokenCounts(
                        input: Int(tokenScale * 0.6),
                        output: Int(tokenScale * 0.15),
                        cacheRead: Int(tokenScale * 0.25)
                    ),
                    costUSD: Decimal(cost)
                )
            )
        }
    }
    return rows
}

private func dashboardFixedDate() -> Date {
    var components = DateComponents()
    components.calendar = Calendar(identifier: .gregorian)
    components.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
    components.year = 2026
    components.month = 7
    components.day = 4
    components.hour = 10
    components.minute = 15
    return components.date ?? Date()
}
