import SwiftUI

/// The Culla brand mark — a thick ring with a centered dot, surrounded by
/// five fixed brand-color "confetti" dots. Reproduced from `design/app-icon.svg`
/// as SwiftUI shapes (not a raster asset) so the central glyph follows
/// `.foregroundStyle`/`.primary` and adapts to light vs dark, while the five
/// accent dots keep their brand colors in both appearances.
///
/// The view has a 1:1 aspect ratio and fills its container. Size at the
/// call site with `.frame(width:height:)`.
struct CullaLogo: View {
    var body: some View {
        // Designed in a 1024×1024 working space — same as the source SVG (its
        // 3000×3000 viewBox is uniformly scaled by 2.92969). Coordinates and
        // radii below port directly from the SVG path data so visual tweaks
        // round-trip cleanly.
        GeometryReader { geo in
            let s = geo.size.width / 1024

            // Central glyph — ring + dot. No explicit fill: picks up
            // `.foregroundStyle` from the call site (defaults to `.primary`,
            // which auto-flips between black on light and white on dark).
            Circle()
                .strokeBorder(lineWidth: 160 * s)
                .frame(width: 484 * s, height: 484 * s)
                .position(x: 510 * s, y: 505 * s)

            Circle()
                .frame(width: 40 * s, height: 40 * s)
                .position(x: 510 * s, y: 505 * s)

            // Five brand-color dots — fixed in both appearances. Order
            // matches the SVG so the layering reads the same.
            dot(scale: s, x: 766, y: 736, r: 80, color: Self.brandBlue)
            dot(scale: s, x: 225, y: 683, r: 65, color: Self.brandYellow)
            dot(scale: s, x: 349, y: 218, r: 58, color: Self.brandRed)
            dot(scale: s, x: 809, y: 359, r: 44, color: Self.brandGreen)
            dot(scale: s, x: 553, y: 822, r: 44, color: Self.brandIndigo)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private func dot(scale s: CGFloat, x: CGFloat, y: CGFloat, r: CGFloat, color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: r * 2 * s, height: r * 2 * s)
            .position(x: x * s, y: y * s)
    }

    // Brand palette — hex values lifted verbatim from design/app-icon.svg.
    private static let brandBlue   = Color(red: 0.322, green: 0.529, blue: 0.843) // #5287D7
    private static let brandYellow = Color(red: 0.953, green: 0.945, blue: 0.376) // #F3F160
    private static let brandRed    = Color(red: 0.996, green: 0.361, blue: 0.333) // #FE5C55
    private static let brandGreen  = Color(red: 0.471, green: 0.929, blue: 0.420) // #78ED6B
    private static let brandIndigo = Color(red: 0.133, green: 0.200, blue: 0.502) // #223380
}

#Preview("Logo — light & dark") {
    HStack(spacing: 24) {
        CullaLogo().frame(width: 22, height: 22)
        CullaLogo().frame(width: 44, height: 44)
        CullaLogo().frame(width: 96, height: 96)
    }
    .padding(40)
}
