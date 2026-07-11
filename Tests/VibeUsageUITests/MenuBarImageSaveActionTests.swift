import Foundation
import Testing
@testable import VibeUsageUI

@Suite struct MenuBarImageSaveActionTests {
    @MainActor
    @Test func activatesTheMenuBarAppBeforePresentingTheSavePanel() {
        var events: [String] = []
        let action = MenuBarImageSaveAction(
            activateApplication: { events.append("activate") },
            presentSavePanel: { _, _ in events.append("present") },
            writeData: { _, _ in }
        )

        action.run(data: Data(), defaultFilename: "VibeUsage.png")

        #expect(events == ["activate", "present"])
    }

    @MainActor
    @Test func writesThePNGToTheURLSelectedByTheUser() {
        let selectedURL = URL(fileURLWithPath: "/tmp/VibeUsage.png")
        let pngData = Data([0x89, 0x50, 0x4e, 0x47])
        var writtenData: Data?
        var writtenURL: URL?
        let action = MenuBarImageSaveAction(
            activateApplication: {},
            presentSavePanel: { _, completion in completion(selectedURL) },
            writeData: { data, url in
                writtenData = data
                writtenURL = url
            }
        )

        action.run(data: pngData, defaultFilename: "VibeUsage.png")

        #expect(writtenData == pngData)
        #expect(writtenURL == selectedURL)
    }
}
