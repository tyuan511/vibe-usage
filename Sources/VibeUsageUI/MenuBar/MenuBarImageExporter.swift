import AppKit
import ScreenCaptureKit

@MainActor
public enum MenuBarImageExporter {
    public static func renderPNGData(window: NSWindow) async -> Data? {
        let usesLightAppearance = window.effectiveAppearance.bestMatch(
            from: [.aqua, .darkAqua]
        ) == .aqua
        let originalBackgroundColor = window.backgroundColor
        let wasOpaque = window.isOpaque
        let adjustedEffectViews = usesLightAppearance
            ? visualEffectViews(in: window.contentView).filter { $0.blendingMode == .behindWindow }
            : []
        if usesLightAppearance {
            window.backgroundColor = .white
            window.isOpaque = true
            adjustedEffectViews.forEach { $0.blendingMode = .withinWindow }
        }
        defer {
            adjustedEffectViews.forEach { $0.blendingMode = .behindWindow }
            if usesLightAppearance {
                window.backgroundColor = originalBackgroundColor
                window.isOpaque = wasOpaque
                window.displayIfNeeded()
            }
        }
        if usesLightAppearance {
            window.displayIfNeeded()
            await Task.yield()
        }

        guard let content = try? await SCShareableContent.currentProcess,
              let shareableWindow = content.windows.first(where: {
                  $0.windowID == CGWindowID(window.windowNumber)
              }) else { return nil }

        let filter = SCContentFilter(desktopIndependentWindow: shareableWindow)
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(SCShareableContent.info(for: filter).pointPixelScale)
        configuration.width = Int(shareableWindow.frame.width * scale)
        configuration.height = Int(shareableWindow.frame.height * scale)
        configuration.showsCursor = false

        guard let image = try? await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        ) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: image)
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func visualEffectViews(in view: NSView?) -> [NSVisualEffectView] {
        guard let view else { return [] }
        let current = (view as? NSVisualEffectView).map { [$0] } ?? []
        return current + view.subviews.flatMap(visualEffectViews)
    }
}
