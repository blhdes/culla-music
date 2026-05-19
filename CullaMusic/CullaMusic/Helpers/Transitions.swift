import SwiftUI

extension AnyTransition {
    /// Recedes a view into the background as it's removed (scale 0.92 + fade)
    /// and springs it forward as it's inserted. Pair with a `.transition(.opacity)`
    /// on the incoming view to get a parallax-style hand-off where the source
    /// screen visibly steps back behind the destination during the morph.
    static var parallaxRecede: AnyTransition {
        .modifier(
            active: ParallaxRecedeModifier(scale: 0.92, opacity: 0),
            identity: ParallaxRecedeModifier(scale: 1.0, opacity: 1.0)
        )
    }
}

private struct ParallaxRecedeModifier: ViewModifier {
    let scale: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .opacity(opacity)
    }
}

extension View {
    /// Applies `matchedGeometryEffect` only when a namespace is provided.
    /// Lets call sites accept an optional `Namespace.ID` (handy for the
    /// next-card preload that should never participate in the hero morph).
    @ViewBuilder
    func matchedHero(id: String, in namespace: Namespace.ID?) -> some View {
        if let namespace {
            self.matchedGeometryEffect(id: id, in: namespace)
        } else {
            self
        }
    }
}
