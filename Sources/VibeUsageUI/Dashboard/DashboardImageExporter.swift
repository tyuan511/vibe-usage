import AppKit
import SwiftUI
import VibeUsageAggregation

/// Renders `DashboardShareCard` to PNG data for saving/copying/sharing from
/// the dashboard window. Uses the same offscreen-render technique as
/// `VibeUsagePreviewRenderer` (NSHostingView hosted in a borderless NSWindow
/// with an explicit `NSAppearance`, drawn via `performAsCurrentDrawingAppearance`
/// + `cacheDisplay`): AppKit dynamic colors (`windowBackgroundColor`,
/// `labelColor`, SwiftUI's `.background` style) resolve against the
/// *containing window's* appearance at draw time, so a window-less view
/// falls back to Aqua and renders dark mode with light-resolved colors. This
/// plumbing is intentionally duplicated here (rather than importing the
/// PreviewRenderer executable target, which isn't a library product) since
/// it's ~30 lines and each target needs a self-contained copy.
@MainActor
public enum DashboardImageExporter {
    /// Renders the share card at its fixed poster size
    /// (`DashboardShareCard.width` x `.height`) and returns PNG data at
    /// `scale`x resolution. Returns `nil` if rendering or PNG encoding fails.
    ///
    /// The share card is a single fixed dark-poster design (Wrapped-style),
    /// independent of system appearance, so it is always rendered with a
    /// `.darkAqua` `NSAppearance` regardless of `darkMode`. The parameter is
    /// kept (rather than removed) purely so this remains a source-compatible,
    /// no-behavior-change drop-in for callers that still pass the caller's
    /// current appearance; it has no effect on the rendered output.
    public static func renderPNGData(
        snapshot: UsageInsightsSnapshot,
        rangeTitle: String,
        darkMode: Bool,
        scale: CGFloat = 2
    ) -> Data? {
        let card = DashboardShareCard(snapshot: snapshot, rangeTitle: rangeTitle)
        let size = NSSize(width: DashboardShareCard.width, height: DashboardShareCard.height)

        return renderPNG(view: card, size: size, scale: scale, dark: true)
    }

    // MARK: - Shared render/encode plumbing (mirrors VibeUsagePreviewRenderer)

    private static func renderPNG(
        view: some View,
        size: NSSize,
        scale: CGFloat,
        dark: Bool
    ) -> Data? {
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(origin: .zero, size: size)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        hostingView.appearance = appearance

        // AppKit dynamic colors resolve against the containing window's
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
            return nil
        }
        bitmap.size = size
        if let appearance {
            appearance.performAsCurrentDrawingAppearance {
                hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
            }
        } else {
            hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        }

        return bitmap.representation(using: .png, properties: [:])
    }
}
