import AppKit
import ScreenCaptureKit

@MainActor
public enum MenuBarImageExporter {
    public static func renderPNGData(window: NSWindow) async -> Data? {
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
}
