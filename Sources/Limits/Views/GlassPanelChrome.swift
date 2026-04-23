import AppKit
import SwiftUI

enum GlassPanelTone {
    case clear
    case regular
}

private struct GlassPanelSurfaceModifier<PanelShape: Shape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    let shape: PanelShape
    let tone: GlassPanelTone
    let interactive: Bool
    let fallbackMaterial: Material

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(shape.fill(Color(nsColor: .windowBackgroundColor)))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(glass, in: shape)
        } else {
            content.background(shape.fill(fallbackMaterial))
        }
    }

    @available(macOS 26.0, *)
    private var glass: Glass {
        let resolvedTone: GlassPanelTone = contrast == .increased ? .regular : tone

        switch (resolvedTone, interactive) {
        case (.clear, false):
            return .clear
        case (.clear, true):
            return .clear.interactive()
        case (.regular, false):
            return .regular
        case (.regular, true):
            return .regular.interactive()
        }
    }
}

extension View {
    func glassPanelSurface<PanelShape: Shape>(
        in shape: PanelShape,
        tone: GlassPanelTone = .clear,
        interactive: Bool = false,
        fallbackMaterial: Material = .regularMaterial
    ) -> some View {
        modifier(
            GlassPanelSurfaceModifier(
                shape: shape,
                tone: tone,
                interactive: interactive,
                fallbackMaterial: fallbackMaterial
            )
        )
    }

    func trayPanelSectionChrome<PanelShape: Shape>(
        in shape: PanelShape,
        interactive: Bool = false
    ) -> some View {
        modifier(TrayPanelSectionModifier(shape: shape, interactive: interactive))
    }
}

private struct TrayPanelSectionModifier<PanelShape: Shape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    let shape: PanelShape
    let interactive: Bool

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.78)))
                .overlay {
                    shape.stroke(borderColor, lineWidth: 1)
                }
        } else if #available(macOS 26.0, *) {
            content
                .glassEffect(glass, in: shape)
                .overlay {
                    shape.stroke(borderColor, lineWidth: 1)
                }
        } else {
            content
                .background(shape.fill(.ultraThinMaterial))
                .overlay {
                    shape.stroke(borderColor, lineWidth: 1)
                }
        }
    }

    private var borderColor: Color {
        if reduceTransparency {
            return .primary.opacity(0.10)
        }

        return colorScheme == .dark ? .white.opacity(0.18) : .white.opacity(0.34)
    }

    @available(macOS 26.0, *)
    private var glass: Glass {
        let base: Glass = contrast == .increased ? .regular : .clear
        return interactive ? base.interactive() : base
    }
}

struct MinimalSeparator: View {
    var body: some View {
        Rectangle()
            .fill(.primary.opacity(0.08))
            .frame(height: 1)
    }
}

struct MinimalProgressTrack: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Capsule()
            .fill(trackFill)
            .overlay {
                Capsule()
                    .stroke(trackStroke, lineWidth: 1)
            }
    }

    private var trackFill: Color {
        colorScheme == .dark ? .white.opacity(0.08) : .black.opacity(0.06)
    }

    private var trackStroke: Color {
        colorScheme == .dark ? .white.opacity(0.20) : .black.opacity(0.16)
    }
}
