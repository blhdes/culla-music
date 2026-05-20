import SwiftUI

/// Shared Liquid Glass primitives with iOS-18 fallbacks. Centralises the
/// `if #available(iOS 26, *)` boilerplate so call sites stay readable and we
/// don't accumulate slightly-different fallback materials across the app.
///
/// Two surfaces:
/// - `.glassSurface(in: shape)`  — non-interactive glass (cards, hero stack)
/// - `.glassSurface(in: shape, interactive: true)` — buttons/tiles that should
///   bounce on press (iOS 26 only; on older OSes the modifier is a no-op on
///   interactivity since the parent button style already handles press states).
///
/// Plus `GlassStack { ... }` — wraps children in `GlassEffectContainer` so
/// adjacent glass shapes share refraction (the intended Apple pattern). On
/// older OSes it's just a passthrough VStack-equivalent.
extension View {
    /// Applies a glass background on iOS 26+, falls back to `.thinMaterial` on
    /// older OSes. `tint` is optional — when set, the glass picks up a wash of
    /// that color (used to mark the selected mode tile on iOS 26).
    @ViewBuilder
    func glassSurface<S: Shape>(
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        if #available(iOS 26.0, *) {
            self.modifier(GlassSurfaceModifier(shape: shape, tint: tint, interactive: interactive))
        } else {
            self.background {
                shape
                    .fill(.thinMaterial)
                    .overlay(shape.fill(tint?.opacity(0.18) ?? .clear))
            }
        }
    }
}

@available(iOS 26.0, *)
private struct GlassSurfaceModifier<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color?
    let interactive: Bool

    func body(content: Content) -> some View {
        // `glassEffect(_:in:)` takes a `Glass` value. We start from `.regular`
        // and layer modifiers (tint, interactive) only when requested — tinting
        // every surface would wash the screen, so it's opt-in per tile.
        var effect: Glass = .regular
        if let tint { effect = effect.tint(tint) }
        if interactive { effect = effect.interactive() }
        return content.glassEffect(effect, in: shape)
    }
}

/// Groups children so iOS 26's Liquid Glass blends adjacent surfaces (their
/// edges refract into each other instead of each being an isolated bubble).
/// On older OSes it's a plain VStack so the layout stays identical.
struct GlassStack<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder var content: () -> Content

    init(spacing: CGFloat = 10, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                VStack(spacing: spacing) { content() }
            }
        } else {
            VStack(spacing: spacing) { content() }
        }
    }
}
