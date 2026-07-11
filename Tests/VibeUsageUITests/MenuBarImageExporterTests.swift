import AppKit
import Testing
@testable import VibeUsageUI

@Suite struct MenuBarImageExporterTests {
    @MainActor
    @Test func lightAppearanceBacksTheTransparentMenuWindowWithWhite() async throws {
        let size = NSSize(width: 160, height: 90)
        let contentView = NSView(frame: NSRect(origin: .zero, size: size))

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView = contentView
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(100))

        let data = await MenuBarImageExporter.renderPNGData(window: window)
        let bitmap = data.flatMap(NSBitmapImageRep.init(data:))
        let background = bitmap?.colorAt(x: 20, y: 20)?.usingColorSpace(.deviceRGB)

        #expect(background?.brightnessComponent ?? 0 > 0.95)
        #expect(background?.alphaComponent == 1)
        #expect(window.backgroundColor == .clear)
        #expect(window.isOpaque == false)
    }
}
