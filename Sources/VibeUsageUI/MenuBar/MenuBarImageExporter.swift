import AppKit
import SwiftUI

@MainActor
public enum MenuBarImageExporter {
    public static func renderPNGData<Content: View>(
        colorScheme: ColorScheme,
        scale: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> Data? {
        let background = colorScheme == .light
            ? Color.white
            : Color(red: 0.12, green: 0.12, blue: 0.12)
        let exportContent = content()
            .environment(\.menuBarExportMode, true)
            .environment(\.colorScheme, colorScheme)
            .background(background)

        let renderer = ImageRenderer(content: exportContent)
        renderer.scale = max(1, scale)
        renderer.isOpaque = true

        guard let image = renderer.nsImage,
              let representation = image.cgImage(
                  forProposedRect: nil,
                  context: nil,
                  hints: nil
              ) else { return nil }

        return NSBitmapImageRep(cgImage: representation)
            .representation(using: .png, properties: [:])
    }
}
