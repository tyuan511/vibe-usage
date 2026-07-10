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
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let isDashboard = arguments.contains("--dashboard")
        let isShareCard = arguments.contains("--share-card")
        let isShareCardSparse = arguments.contains("--share-card-sparse")
        let isDark = arguments.contains("--dark")
        let outputPath = arguments.first(where: { !$0.hasPrefix("--") })
            ?? ((isShareCard || isShareCardSparse) ? "docs/usage-share-preview.png" : (isDashboard ? "dashboard-preview.png" : "docs/usage-share-preview.png"))

        if isShareCardSparse {
            try renderShareCard(outputPath: outputPath, isDark: isDark, sparse: true)
        } else if isShareCard {
            try renderShareCard(outputPath: outputPath, isDark: isDark, sparse: false)
        } else if isDashboard {
            try renderDashboard(outputPath: outputPath, isDark: isDark)
        } else {
            try renderShareCard(outputPath: outputPath, isDark: isDark, sparse: false)
        }
    }

    // MARK: - Dashboard preview

    private static func renderDashboard(outputPath: String, isDark: Bool) throws {
        let snapshot = makeDashboardSnapshot()
        let quota = makeQuotaSnapshot()
        let size = NSSize(width: 1040, height: 1600)

        let view = ZStack(alignment: .top) {
            Color(nsColor: .windowBackgroundColor)
            DashboardWindowView(
                snapshot: snapshot,
                isLoading: false,
                quota: quota,
                selectedRange: .constant(.last30Days),
                onRangeChange: {},
                onRefresh: {}
            )
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .environment(\.locale, Locale(identifier: "zh_Hans_CN"))
        .environment(\.colorScheme, isDark ? .dark : .light)
        .preferredColorScheme(isDark ? .dark : .light)

        try renderPNG(view: view, size: size, scale: 2, outputPath: outputPath, dark: isDark)
    }

    // MARK: - Share card preview

    /// The share card is a single fixed dark-poster design regardless of
    /// system appearance, so `isDark` is a no-op here (kept only so the
    /// `--dark` flag remains harmless to pass); the card always renders at
    /// its fixed `DashboardShareCard.width` x `.height` size, never measured
    /// from fitting content.
    private static func renderShareCard(outputPath: String, isDark: Bool, sparse: Bool) throws {
        let snapshot = sparse ? makeSparseShareCardSnapshot() : makeDashboardSnapshot()
        let size = NSSize(width: DashboardShareCard.width, height: DashboardShareCard.height)

        let view = DashboardShareCard(snapshot: snapshot, rangeTitle: UsageInsightsRange.last30Days.displayName)
            .environment(\.locale, Locale(identifier: "zh_Hans_CN"))

        try renderPNG(view: view, size: size, scale: 2, outputPath: outputPath, dark: true)
    }

    /// Low-data mock: a single agent source and two projects, to verify the
    /// poster layout doesn't collapse or leave awkward gaps when there's
    /// little to show (no multi-source superlative contrast, thin trend
    /// line, small stat grid values).
    private static func makeSparseShareCardSnapshot() -> UsageInsightsSnapshot {
        let claude = ClaudeCodeAdapter().descriptor
        let now = dashboardFixedDate()
        let dayCount = 30

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let start = calendar.date(byAdding: .day, value: -(dayCount - 1), to: calendar.startOfDay(for: now)) ?? now
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        var dailyRows: [DailyUsageSummary] = []
        for offset in 0..<dayCount {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
            let isActive = offset % 3 != 0
            guard isActive else { continue }
            let cost = Decimal(2 + (offset % 5))
            dailyRows.append(
                DailyUsageSummary(
                    day: formatter.string(from: day),
                    sourceID: claude.id,
                    tokens: TokenCounts(input: 4_000, output: 900, cacheRead: 1_200),
                    costUSD: cost
                )
            )
        }

        let totals = dailyRows.reduce(UsageTotals()) { partial, row in
            UsageTotals(
                tokens: partial.tokens + row.tokens,
                costUSD: partial.costUSD + row.costUSD,
                eventCount: partial.eventCount + 1
            )
        }

        let sources: [SourceUsageSummary] = [
            SourceUsageSummary(descriptor: claude, totals: totals)
        ]

        let models: [ModelUsageSummary] = [
            ModelUsageSummary(
                modelFamily: "claude-sonnet-4",
                sourceID: claude.id,
                tokens: totals.tokens,
                costUSD: totals.costUSD,
                eventCount: totals.eventCount
            )
        ]

        let projects: [ProjectUsageSummary] = [
            ProjectUsageSummary(
                project: "/Users/yuantang/code/vibe-usage",
                sourceID: claude.id,
                tokens: TokenCounts(input: 40_000, output: 9_000, cacheRead: 12_000),
                costUSD: totals.costUSD * Decimal(0.7),
                eventCount: totals.eventCount * 7 / 10,
                sessionCount: 8
            ),
            ProjectUsageSummary(
                project: "sandbox-experiment",
                sourceID: claude.id,
                tokens: TokenCounts(input: 6_000, output: 1_400, cacheRead: 1_800),
                costUSD: totals.costUSD * Decimal(0.3),
                eventCount: totals.eventCount * 3 / 10,
                sessionCount: 2
            )
        ]

        let activeDayCount = Set(dailyRows.map(\.day)).count

        return UsageInsightsSnapshot(
            generatedAt: now,
            rangeStartDay: dailyRows.map(\.day).min() ?? "2026-06-05",
            rangeEndDay: dailyRows.map(\.day).max() ?? "2026-07-04",
            totals: totals,
            daily: dailyRows,
            projects: projects,
            models: models,
            sources: sources,
            previousTotals: UsageTotals(tokens: totals.tokens, costUSD: totals.costUSD * Decimal(1.1), eventCount: totals.eventCount),
            activeDayCount: activeDayCount
        )
    }

    // MARK: - Shared render/encode plumbing

    private static func renderPNG(
        view: some View,
        size: NSSize,
        scale: CGFloat,
        outputPath: String,
        dark: Bool = false
    ) throws {
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(origin: .zero, size: size)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        hostingView.appearance = appearance

        // AppKit dynamic colors (labelColor, windowBackgroundColor, SwiftUI's
        // `.background` style) resolve against the containing window's
        // appearance at draw time; a window-less view falls back to Aqua and
        // renders dark mode with light-resolved colors.
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw RenderError.bitmapAllocationFailed
        }
        bitmap.size = size
        if let appearance {
            appearance.performAsCurrentDrawingAppearance {
                hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
            }
        } else {
            hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        }

        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw RenderError.pngEncodingFailed
        }

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
    case bitmapAllocationFailed
    case pngEncodingFailed
}

// MARK: - Quota mock data

/// Claude `.ok` with three windows spanning all three tint thresholds
/// (green/amber/red) and Codex `.notConnected` to show a non-ok state renders
/// cleanly alongside a populated one.
private func makeQuotaSnapshot() -> QuotaSnapshot {
    let now = fixedDate()

    let claudeWindows: [QuotaWindow] = [
        QuotaWindow(
            id: "five_hour",
            label: VibeUsageStrings.text(zh: "5 小时额度", en: "5-Hour Quota"),
            usedFraction: 0.62,
            usedPercentText: "62%",
            resetsAt: now.addingTimeInterval(2 * 3600 + 18 * 60),
            resetCountdownText: QuotaFormatting.countdownText(resetsAt: now.addingTimeInterval(2 * 3600 + 18 * 60), now: now)
        ),
        QuotaWindow(
            id: "seven_day",
            label: VibeUsageStrings.text(zh: "7 日额度", en: "7-Day Quota"),
            usedFraction: 0.78,
            usedPercentText: "78%",
            resetsAt: now.addingTimeInterval(3 * 86400 + 4 * 3600),
            resetCountdownText: QuotaFormatting.countdownText(resetsAt: now.addingTimeInterval(3 * 86400 + 4 * 3600), now: now)
        ),
        QuotaWindow(
            id: "seven_day_opus",
            label: VibeUsageStrings.text(zh: "7 日 Opus 额度", en: "7-Day Opus Quota"),
            usedFraction: 0.91,
            usedPercentText: "91%",
            resetsAt: now.addingTimeInterval(3 * 86400 + 4 * 3600),
            resetCountdownText: QuotaFormatting.countdownText(resetsAt: now.addingTimeInterval(3 * 86400 + 4 * 3600), now: now)
        )
    ]

    return QuotaSnapshot(
        sources: [
            QuotaSourceSnapshot(sourceID: .claudeCode, displayName: "Claude", state: .ok(claudeWindows), fetchedAt: now, subscriptionTier: "max"),
            QuotaSourceSnapshot(sourceID: .codexCLI, displayName: "Codex", state: .notConnected, fetchedAt: now)
        ],
        generatedAt: now
    )
}

private func fixedDate() -> Date {
    var components = DateComponents()
    components.calendar = Calendar(identifier: .gregorian)
    components.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
    components.year = 2026
    components.month = 7
    components.day = 2
    components.hour = 16
    components.minute = 3
    return components.date ?? Date()
}

// MARK: - Dashboard mock data (deliberately messy, mirrors real-world data)

/// Mock data mirrors the shape of real usage data that motivated this
/// redesign: one source dominating spend by orders of magnitude, Claude-style
/// munged paths, Codex-style date-folder "projects", an empty project, long
/// hyphenated real directory names, lumpy daily activity with zero days and a
/// spike, and a previous period ~20% lower so the delta badge has something
/// to show.
private func makeDashboardSnapshot() -> UsageInsightsSnapshot {
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

    let projects = makeProjectRows(opencode: opencode.id, codex: codex.id, claude: claude.id, gemini: gemini.id)
    let models = makeModelRows(opencode: opencode.id, codex: codex.id, claude: claude.id, gemini: gemini.id)

    let previousTotals = UsageTotals(
        tokens: TokenCounts(
            input: Int(Double(grand.tokens.input) * 0.8),
            output: Int(Double(grand.tokens.output) * 0.8),
            cacheRead: Int(Double(grand.tokens.cacheRead) * 0.8)
        ),
        costUSD: grand.costUSD * Decimal(0.8),
        eventCount: Int(Double(grand.eventCount) * 0.8)
    )

    let activeDayCount = Set(dailyRows.map(\.day)).count

    return UsageInsightsSnapshot(
        generatedAt: now,
        rangeStartDay: dailyRows.map(\.day).min() ?? "2026-06-05",
        rangeEndDay: dailyRows.map(\.day).max() ?? "2026-07-04",
        totals: grand,
        daily: dailyRows,
        projects: projects,
        models: models,
        sources: sourceSummaries,
        previousTotals: previousTotals,
        activeDayCount: activeDayCount
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

private func makeProjectRows(
    opencode: AgentSourceID,
    codex: AgentSourceID,
    claude: AgentSourceID,
    gemini: AgentSourceID
) -> [ProjectUsageSummary] {
    [
        // Same real project reported by two different sources with two
        // different raw representations -- must merge into one row in the UI.
        ProjectUsageSummary(
            project: "-Users-yuantang-code-vibe-usage",
            sourceID: claude,
            tokens: TokenCounts(input: 210_000, output: 54_000, cacheRead: 80_000),
            costUSD: Decimal(string: "24.55")!,
            eventCount: 58,
            sessionCount: 12
        ),
        ProjectUsageSummary(
            project: "/Users/yuantang/code/vibe-usage",
            sourceID: opencode,
            tokens: TokenCounts(input: 8_900_000, output: 1_100_000, cacheRead: 2_000_000),
            costUSD: Decimal(string: "1180.42")!,
            eventCount: 612,
            sessionCount: 44
        ),
        ProjectUsageSummary(
            project: "/Users/yuantang/code/agent-orchestrator",
            sourceID: opencode,
            tokens: TokenCounts(input: 24_000_000, output: 3_200_000, cacheRead: 5_400_000),
            costUSD: Decimal(string: "3402.11")!,
            eventCount: 1580,
            sessionCount: 96
        ),
        ProjectUsageSummary(
            project: "/Users/yuantang/code/agent-orchestrator",
            sourceID: codex,
            tokens: TokenCounts(input: 6_400_000, output: 980_000, cacheRead: 1_800_000, reasoning: 320_000),
            costUSD: Decimal(string: "812.90")!,
            eventCount: 420,
            sessionCount: 31
        ),
        // Codex date-folder "project" values: not real projects, must land
        // in the ungrouped bucket, not as individual date rows.
        ProjectUsageSummary(
            project: "2025/09/19",
            sourceID: codex,
            tokens: TokenCounts(input: 1_200_000, output: 180_000, cacheRead: 300_000),
            costUSD: Decimal(string: "140.22")!,
            eventCount: 88,
            sessionCount: 6
        ),
        ProjectUsageSummary(
            project: "2025/09/20",
            sourceID: codex,
            tokens: TokenCounts(input: 900_000, output: 140_000, cacheRead: 220_000),
            costUSD: Decimal(string: "98.17")!,
            eventCount: 61,
            sessionCount: 4
        ),
        // Empty project -> also ungrouped.
        ProjectUsageSummary(
            project: "",
            sourceID: codex,
            tokens: TokenCounts(input: 400_000, output: 62_000, cacheRead: 90_000),
            costUSD: Decimal(string: "44.60")!,
            eventCount: 22,
            sessionCount: 2
        ),
        ProjectUsageSummary(
            project: "-Users-yuantang-code-super-long-hyphenated-client-project-name",
            sourceID: opencode,
            tokens: TokenCounts(input: 12_000_000, output: 1_600_000, cacheRead: 2_900_000),
            costUSD: Decimal(string: "1890.77")!,
            eventCount: 740,
            sessionCount: 52
        ),
        ProjectUsageSummary(
            project: "/Users/yuantang/code/marketing-site",
            sourceID: opencode,
            tokens: TokenCounts(input: 4_200_000, output: 560_000, cacheRead: 900_000),
            costUSD: Decimal(string: "620.05")!,
            eventCount: 260,
            sessionCount: 20
        ),
        ProjectUsageSummary(
            project: "/Users/yuantang/code/infra-scripts",
            sourceID: codex,
            tokens: TokenCounts(input: 1_800_000, output: 260_000, cacheRead: 420_000, reasoning: 80_000),
            costUSD: Decimal(string: "312.44")!,
            eventCount: 140,
            sessionCount: 15
        ),
        ProjectUsageSummary(
            project: "-Users-yuantang-Documents-notes",
            sourceID: claude,
            tokens: TokenCounts(input: 60_000, output: 14_000, cacheRead: 22_000),
            costUSD: Decimal(string: "8.71")!,
            eventCount: 18,
            sessionCount: 5
        ),
        ProjectUsageSummary(
            project: "sandbox-experiment",
            sourceID: gemini,
            tokens: TokenCounts(input: 2_100, output: 640, cacheRead: 300),
            costUSD: Decimal(string: "0.19")!,
            eventCount: 3,
            sessionCount: 1
        ),
        ProjectUsageSummary(
            project: "/Users/yuantang/code/data-pipeline-v2",
            sourceID: opencode,
            tokens: TokenCounts(input: 3_100_000, output: 410_000, cacheRead: 780_000),
            costUSD: Decimal(string: "451.30")!,
            eventCount: 190,
            sessionCount: 14
        ),
        ProjectUsageSummary(
            project: "/Users/yuantang/code/design-system",
            sourceID: claude,
            tokens: TokenCounts(input: 26_000, output: 6_000, cacheRead: 9_000),
            costUSD: Decimal(string: "3.15")!,
            eventCount: 9,
            sessionCount: 3
        )
    ]
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
