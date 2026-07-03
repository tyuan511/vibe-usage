import AppKit
import SwiftUI
import VibeUsageCore

struct AgentSourceIcon: View {
    let descriptor: AgentSourceDescriptor
    let size: CGFloat
    let imageSize: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    init(descriptor: AgentSourceDescriptor, size: CGFloat, imageSize: CGFloat = 14) {
        self.descriptor = descriptor
        self.size = size
        self.imageSize = imageSize
    }

    var body: some View {
        Group {
            if let image = AgentIconStore.image(for: descriptor.id, colorScheme: colorScheme) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: imageSize, height: imageSize)
            } else {
                Image(systemName: descriptor.iconSystemName)
                    .font(.system(size: imageSize * 0.75, weight: .medium))
                    .foregroundStyle(Color(hex: descriptor.tintColorHex))
                    .frame(width: imageSize, height: imageSize)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

enum AgentIconStore {
    static func image(for sourceID: AgentSourceID, colorScheme: ColorScheme) -> NSImage? {
        let appearance = colorScheme == .dark ? "dark" : "light"
        guard let url = VibeUsageUIResources.bundle.url(
            forResource: sourceID.rawValue,
            withExtension: "png",
            subdirectory: "AgentIcons/\(appearance)"
        ) else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}
