import SwiftUI

private struct MenuBarExportModeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var menuBarExportMode: Bool {
        get { self[MenuBarExportModeKey.self] }
        set { self[MenuBarExportModeKey.self] = newValue }
    }
}

struct MenuGlassEffectContainer<Content: View>: View {
    @Environment(\.menuBarExportMode) private var isExporting
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if isExporting {
            content
        } else {
            GlassEffectContainer {
                content
            }
        }
    }
}

private struct MenuCardModifier<CardShape: Shape>: ViewModifier {
    @Environment(\.menuBarExportMode) private var isExporting
    @Environment(\.colorScheme) private var colorScheme
    let shape: CardShape

    @ViewBuilder
    func body(content: Content) -> some View {
        if isExporting {
            content
                .background(exportFill, in: shape)
                .overlay {
                    shape.stroke(exportStroke, lineWidth: 1)
                }
        } else {
            content.glassEffect(.regular, in: shape)
        }
    }

    private var exportFill: Color {
        colorScheme == .light
            ? Color.black.opacity(0.045)
            : Color.white.opacity(0.09)
    }

    private var exportStroke: Color {
        colorScheme == .light
            ? Color.black.opacity(0.10)
            : Color.white.opacity(0.12)
    }
}

extension View {
    func menuCard<CardShape: Shape>(in shape: CardShape) -> some View {
        modifier(MenuCardModifier(shape: shape))
    }
}
