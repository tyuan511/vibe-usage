import AppKit
import SwiftUI
import VibeUsageAdapter
import VibeUsageAggregation
import VibeUsageCore
import VibeUsageUI

@main
@MainActor
struct VibeUsagePreviewRenderer {
    static func main() throws {
        let outputPath = CommandLine.arguments.dropFirst().first ?? "docs/usage-preview.png"
        let snapshot = makeSnapshot()
        let sources = snapshot.discoveredSources
        let size = NSSize(width: 388, height: 880)

        let view = ZStack(alignment: .top) {
            Color(nsColor: .windowBackgroundColor)
            MenuBarUsageView(
                snapshot: snapshot,
                isRefreshing: false,
                lastError: nil,
                configurableAgentSources: sources,
                hiddenAgentSourceIDs: [],
                selectedDateRange: .constant(.today),
                selectedModelFilter: .constant([]),
                onRefresh: {},
                onFilterChange: {},
                onAgentDisplayCommit: { _ in },
                onQuit: {}
            )
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .environment(\.locale, Locale(identifier: "zh_Hans_CN"))
        .environment(\.colorScheme, .light)

        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * 2),
            pixelsHigh: Int(size.height * 2),
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
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)

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

private func makeSnapshot() -> UsageDashboardSnapshot {
    let generatedAt = fixedDate()
    let descriptors = [
        ClaudeCodeAdapter().descriptor,
        CodexCLIAdapter().descriptor,
        GeminiUsageAdapter().descriptor,
        QwenUsageAdapter().descriptor,
        OpenCodeUsageAdapter().descriptor,
        GitHubCopilotUsageAdapter().descriptor
    ]

    let sources: [SourceUsageSummary] = [
        source(descriptors[0], input: 1_870_000, output: 438_000, cache: 1_120_000, reasoning: 0, cost: "5.92", events: 318),
        source(descriptors[1], input: 1_480_000, output: 382_000, cache: 910_000, reasoning: 245_000, cost: "4.31", events: 204),
        source(descriptors[2], input: 1_240_000, output: 344_000, cache: 520_000, reasoning: 0, cost: "3.08", events: 187),
        source(descriptors[3], input: 740_000, output: 216_000, cache: 318_000, reasoning: 92_000, cost: "1.42", events: 96),
        source(descriptors[4], input: 512_000, output: 152_000, cache: 218_000, reasoning: 0, cost: "1.21", events: 74),
        source(descriptors[5], input: 420_000, output: 128_000, cache: 182_000, reasoning: 36_000, cost: "0.94", events: 62)
    ]

    let totals = sources.reduce(UsageTotals()) { partial, row in
        UsageTotals(
            tokens: partial.tokens + row.totals.tokens,
            costUSD: partial.costUSD + row.totals.costUSD,
            eventCount: partial.eventCount + row.totals.eventCount
        )
    }

    let models: [ModelUsageSummary] = [
        model("claude-sonnet-4", descriptors[0].id, input: 1_780_000, output: 402_000, cache: 1_080_000, reasoning: 0, cost: "4.87", events: 256),
        model("gpt-5-codex", descriptors[1].id, input: 1_260_000, output: 312_000, cache: 820_000, reasoning: 210_000, cost: "3.94", events: 168),
        model("gemini-2.5-pro", descriptors[2].id, input: 1_130_000, output: 320_000, cache: 480_000, reasoning: 0, cost: "3.08", events: 172),
        model("qwen3-coder-plus", descriptors[3].id, input: 710_000, output: 190_000, cache: 304_000, reasoning: 92_000, cost: "1.42", events: 92),
        model("kimi-k2.6", descriptors[4].id, input: 480_000, output: 144_000, cache: 190_000, reasoning: 0, cost: "1.01", events: 61),
        model("gpt-5", descriptors[5].id, input: 420_000, output: 128_000, cache: 182_000, reasoning: 36_000, cost: "0.94", events: 62)
    ]

    return UsageDashboardSnapshot(
        generatedAt: generatedAt,
        rangeStartDay: "2026-07-02",
        rangeEndDay: "2026-07-02",
        totals: totals,
        sources: sources,
        daily: todayRows(from: sources),
        activity: activityRows(endingAt: generatedAt, descriptors: descriptors),
        models: models,
        availableModels: models,
        discoveredSources: descriptors
    )
}

private func source(
    _ descriptor: AgentSourceDescriptor,
    input: Int,
    output: Int,
    cache: Int,
    reasoning: Int,
    cost: String,
    events: Int
) -> SourceUsageSummary {
    SourceUsageSummary(
        descriptor: descriptor,
        totals: UsageTotals(
            tokens: TokenCounts(input: input, output: output, cacheRead: cache, reasoning: reasoning),
            costUSD: Decimal(string: cost) ?? 0,
            eventCount: events
        )
    )
}

private func model(
    _ family: String,
    _ sourceID: AgentSourceID,
    input: Int,
    output: Int,
    cache: Int,
    reasoning: Int,
    cost: String,
    events: Int
) -> ModelUsageSummary {
    ModelUsageSummary(
        modelFamily: family,
        sourceID: sourceID,
        tokens: TokenCounts(input: input, output: output, cacheRead: cache, reasoning: reasoning),
        costUSD: Decimal(string: cost) ?? 0,
        eventCount: events
    )
}

private func todayRows(from sources: [SourceUsageSummary]) -> [DailyUsageSummary] {
    sources.map {
        DailyUsageSummary(
            day: "2026-07-02",
            sourceID: $0.descriptor.id,
            tokens: $0.totals.tokens,
            costUSD: $0.totals.costUSD
        )
    }
}

private func activityRows(endingAt date: Date, descriptors: [AgentSourceDescriptor]) -> [DailyUsageSummary] {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600) ?? .current
    let start = calendar.date(byAdding: .day, value: -167, to: calendar.startOfDay(for: date)) ?? date
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd"

    return (0..<168).compactMap { offset in
        guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
        let source = descriptors[offset % descriptors.count]
        let intensity = [0, 1, 2, 4, 7, 11, 16, 22, 31, 44][(offset * 7 + offset / 3) % 10]
        let active = intensity > 0
        return DailyUsageSummary(
            day: formatter.string(from: day),
            sourceID: source.id,
            tokens: active ? TokenCounts(
                input: intensity * 21_000,
                output: intensity * 5_600,
                cacheRead: intensity * 12_000,
                reasoning: intensity * 1_800
            ) : .zero,
            costUSD: Decimal(intensity) / Decimal(11)
        )
    }
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
