import SwiftUI

/// The Culla Music brand mark: an open ring (a "C", a record, a cradle)
/// holding a blue centre dot. Drawn from the official artwork, never redrawn
/// in code. `design/build-mark.py` writes it as two asset-catalog layers that
/// share one frame, the same two layers the Icon Composer app icon uses:
/// - `CullaMarkRing` is a template image, so it follows `.foregroundStyle`
///   (default `.primary`: black on light, white on dark).
/// - `CullaMarkDot` keeps its brand blue (#0A09EF) in both appearances.
///
/// The view is 1:1 and fills its container. Size it at the call site with
/// `.frame(width:height:)`.
struct CullaLogo: View {
    var body: some View {
        ZStack {
            Image("CullaMarkRing")
                .resizable()
                .scaledToFit()
            Image("CullaMarkDot")
                .resizable()
                .scaledToFit()
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

#Preview("Logo — light & dark") {
    HStack(spacing: 24) {
        CullaLogo().frame(width: 22, height: 22)
        CullaLogo().frame(width: 44, height: 44)
        CullaLogo().frame(width: 96, height: 96)
    }
    .padding(40)
}
