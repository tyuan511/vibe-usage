import SwiftUI
import VibeUsageCore

public struct StartupFailureView: View {
    let message: String
    let onQuit: () -> Void

    public init(message: String, onQuit: @escaping () -> Void) {
        self.message = message
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                VibeUsageLogo(size: 24)
                Text("VibeUsage")
                    .font(.headline)
            }

            Label(message, systemImage: "externaldrive.badge.exclamationmark")
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)

            Text(UIStrings.text(
                zh: "请检查磁盘空间与 Application Support 目录权限后重试。",
                en: "Check disk space and Application Support permissions, then relaunch."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(UIStrings.text(zh: "退出", en: "Quit"), action: onQuit)
            }
        }
        .padding(14)
        .frame(width: 388)
    }
}
