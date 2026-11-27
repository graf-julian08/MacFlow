import SwiftUI

/// A glass-effect modifier that uses real Apple Liquid Glass on macOS 26+
/// and falls back to .ultraThinMaterial on older versions.
///
/// Uses `.regular` glass style for the full refraction + specular edge
/// effect, with a slight dark tint behind it.
struct GlassEffectModifier: ViewModifier {
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(Color.black.opacity(0.12))
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
                }
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}

extension View {
    func macFlowGlass(cornerRadius: CGFloat = 16) -> some View {
        modifier(GlassEffectModifier(cornerRadius: cornerRadius))
    }
}
