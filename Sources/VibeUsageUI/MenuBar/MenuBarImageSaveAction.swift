import Foundation

@MainActor
struct MenuBarImageSaveAction {
    var activateApplication: () -> Void
    var presentSavePanel: (_ defaultFilename: String, _ completion: @escaping (URL?) -> Void) -> Void
    var writeData: (Data, URL) throws -> Void

    func run(data: Data, defaultFilename: String) {
        activateApplication()
        presentSavePanel(defaultFilename) { url in
            guard let url else { return }
            try? writeData(data, url)
        }
    }
}
