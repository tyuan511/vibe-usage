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

/// Compact scrollable list for the menu popover. Hides the system scroller —
/// AppKit falls back to the ~14pt legacy scroller whenever a mouse is
/// connected or "Show scroll bars" is Always, which overwhelms a 388pt menu —
/// and signals hidden overflow with top/bottom fade-out edges instead.
struct MenuScrollList<Content: View>: View {
    private let height: CGFloat
    private let content: Content

    @State private var canScrollUp = false
    @State private var canScrollDown = false

    private static var fadeHeight: CGFloat { 18 }

    init(height: CGFloat, @ViewBuilder content: () -> Content) {
        self.height = height
        self.content = content()
    }

    var body: some View {
        ScrollView(.vertical) {
            content
        }
        .scrollIndicators(.never)
        .frame(height: height)
        .onScrollGeometryChange(for: EdgeState.self) { geometry in
            EdgeState(
                canScrollUp: geometry.contentOffset.y > 1,
                canScrollDown: geometry.contentOffset.y + geometry.containerSize.height
                    < geometry.contentSize.height - 1
            )
        } action: { _, state in
            canScrollUp = state.canScrollUp
            canScrollDown = state.canScrollDown
        }
        .mask(fadeMask)
        .animation(.easeInOut(duration: 0.15), value: canScrollUp)
        .animation(.easeInOut(duration: 0.15), value: canScrollDown)
    }

    private var fadeMask: some View {
        let fade = min(Self.fadeHeight / max(height, 1), 0.25)
        return LinearGradient(
            stops: [
                .init(color: canScrollUp ? .clear : .black, location: 0),
                .init(color: .black, location: fade),
                .init(color: .black, location: 1 - fade),
                .init(color: canScrollDown ? .clear : .black, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private struct EdgeState: Equatable {
        let canScrollUp: Bool
        let canScrollDown: Bool
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
