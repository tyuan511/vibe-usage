import AppKit
import SwiftUI

struct MenuMetricCard: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct MenuSectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

struct MenuEmptyState: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 42)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct VibeUsageLogo: View {
    private let size: CGFloat

    init(size: CGFloat) {
        self.size = size
    }

    var body: some View {
        Image(nsImage: Self.logoImage)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }

    private static var logoImage: NSImage {
        guard let url = VibeUsageUIResources.bundle.url(forResource: "logo", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            return NSApp.applicationIconImage
        }
        return image
    }
}
