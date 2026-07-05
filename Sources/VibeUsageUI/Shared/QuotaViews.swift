import SwiftUI
import VibeUsageCore
import VibeUsageQuota

/// Transient in-flight connect state the UI overlays on top of a source's
/// last-known `QuotaSourceState`, since "connecting" isn't itself part of
/// `QuotaSourceState` (it's UI-local, not fetched from the network).
public enum QuotaConnectUIState: Sendable, Equatable {
    /// Codex-style: browser opened, waiting for the loopback callback.
    case waitingForBrowser
    /// A connect attempt just failed; show the message inline.
    case failed(String)
}

/// A single quota source's row: agent icon + display name, then either a
/// stack of labeled progress bars (`.ok` state), a connect affordance
/// (`.notConnected`/`.unauthorized`), an inline paste field (Claude connect
/// in progress), a spinner (Codex connect in progress), or a muted status
/// line (`.networkError`/`.disabled`).
struct QuotaSourceRow: View {
    let snapshot: QuotaSourceSnapshot
    let descriptor: AgentSourceDescriptor?
    var connectUIState: QuotaConnectUIState? = nil
    var onConnect: (AgentSourceID) -> Void = { _ in }
    var onDisconnect: (AgentSourceID) -> Void = { _ in }
    var onCancelConnect: (AgentSourceID) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let descriptor {
                AgentSourceIcon(descriptor: descriptor, size: 18)
            }
            Text(snapshot.displayName)
                .font(.callout)
                .lineLimit(1)
            if let tier = snapshot.subscriptionTier {
                SubscriptionTierBadge(rawTier: tier)
            }
            Spacer(minLength: 8)
            headerTrailingControl
        }
    }

    /// The control shown on the right of the name row: a connect button when
    /// the account isn't usable yet (so it sits inline with the name rather
    /// than on its own "未连接" line), or a disconnect button once connected.
    @ViewBuilder
    private var headerTrailingControl: some View {
        if connectUIState == nil {
            switch snapshot.state {
            case .ok:
                disconnectButton
            case .notConnected, .unauthorized:
                connectButton
            case .networkError, .disabled:
                EmptyView()
            }
        }
    }

    private var disconnectButton: some View {
        Button {
            onDisconnect(snapshot.sourceID)
        } label: {
            Image(systemName: "xmark.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(QuotaUIStrings.disconnect)
    }

    @ViewBuilder
    private var content: some View {
        if let connectUIState {
            connectingContent(connectUIState)
        } else {
            switch snapshot.state {
            case .ok(let windows) where !windows.isEmpty:
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(windows) { window in
                        QuotaWindowBar(window: window)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 26)
            case .ok:
                statusLine(QuotaUIStrings.noWindowData)
            case .notConnected:
                // No body: the connect button lives inline on the name row.
                EmptyView()
            case .unauthorized:
                statusLine(QuotaUIStrings.unauthorized, tint: .orange)
            case .networkError(let message):
                statusLine(QuotaUIStrings.networkError(message))
            case .disabled:
                statusLine(QuotaUIStrings.disabled)
            }
        }
    }

    @ViewBuilder
    private func connectingContent(_ state: QuotaConnectUIState) -> some View {
        switch state {
        case .waitingForBrowser:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(QuotaUIStrings.waitingForBrowser)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 26)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                connectButton
            }
            .padding(.leading, 26)
        }
    }

    private var connectButton: some View {
        Button(QuotaUIStrings.connectLabel(for: snapshot.sourceID)) {
            onConnect(snapshot.sourceID)
        }
        .controlSize(.small)
    }

    private func statusLine(_ text: String, tint: Color = .secondary) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(tint)
            .padding(.leading, 26)
    }
}

/// A small capsule showing a connected account's subscription tier (e.g.
/// "Free"/"Pro"/"Max"), next to its name in the header row. Free renders
/// muted; any paid tier renders in a consistent accent color — the two
/// providers' tiers aren't reliably comparable finer than that (see
/// `QuotaFormatting.subscriptionTierBadgeText`), so this doesn't try to rank
/// paid tiers against each other.
struct SubscriptionTierBadge: View {
    let rawTier: String

    private var isFree: Bool {
        rawTier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "free"
    }

    var body: some View {
        Text(QuotaFormatting.subscriptionTierBadgeText(rawTier))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(isFree ? .secondary : Color.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                (isFree ? Color.secondary : Color.accentColor).opacity(0.14),
                in: Capsule()
            )
    }
}

/// A single window's thin progress bar with trailing "87% · 3h12m" text,
/// tinted by utilization (green < 70%, amber 70-90%, red > 90%).
struct QuotaWindowBar: View {
    let window: QuotaWindow

    private var tint: Color {
        switch window.usedFraction {
        case ..<0.7: .green
        case ..<0.9: .orange
        default: .red
        }
    }

    private var trailingText: String {
        if let countdown = window.resetCountdownText {
            return "\(window.usedPercentText) · \(countdown)"
        }
        return window.usedPercentText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(window.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(trailingText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ProgressView(value: window.usedFraction)
                .progressViewStyle(.linear)
                .tint(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Bilingual strings for non-ok quota states, kept alongside the view since
/// they're only ever used here.
enum QuotaUIStrings {
    static let sectionTitle = UIStrings.text(zh: "限额", en: "Limits")
    static let noWindowData = UIStrings.text(zh: "暂无额度数据", en: "No quota data")
    static let unauthorized = UIStrings.text(zh: "登录已过期，请重新连接", en: "Session expired, reconnect")
    static func networkError(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return UIStrings.text(zh: "网络错误", en: "Network error")
        }
        return UIStrings.text(zh: "网络错误：\(trimmed)", en: "Network error: \(trimmed)")
    }
    static let disabled = UIStrings.text(zh: "已关闭", en: "Disabled")
    static let disconnect = UIStrings.text(zh: "断开连接", en: "Disconnect")
    static let waitingForBrowser = UIStrings.text(zh: "等待浏览器授权…", en: "Waiting for browser authorization…")

    static func connectLabel(for sourceID: AgentSourceID) -> String {
        switch sourceID {
        case .claudeQuota:
            UIStrings.text(zh: "连接 Claude 账号", en: "Connect Claude")
        case .codexQuota:
            UIStrings.text(zh: "连接 Codex 账号", en: "Connect Codex")
        default:
            UIStrings.text(zh: "连接", en: "Connect")
        }
    }
}
