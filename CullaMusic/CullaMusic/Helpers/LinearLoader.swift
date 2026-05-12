import SwiftUI

/// A thin animated capsule loader — used where the surrounding chrome is
/// hairline and a default spinner would visually dominate. Reads tint from
/// the ambient `ShapeStyle` hierarchy (`.tertiary` track, `.secondary` pill)
/// so it adapts to dark/light mode without explicit colors.
struct LinearLoader: View {
    var width: CGFloat = 28
    var height: CGFloat = 2

    @State private var phase: CGFloat = 0

    private var pillWidth: CGFloat { width * 0.45 }
    private var travel: CGFloat { width - pillWidth }

    var body: some View {
        Capsule()
            .fill(.tertiary)
            .frame(width: width, height: height)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(.secondary)
                    .frame(width: pillWidth, height: height)
                    .offset(x: phase * travel)
            }
            .clipShape(Capsule())
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 0.85).repeatForever(autoreverses: true)
                ) {
                    phase = 1
                }
            }
    }
}

#Preview {
    VStack(spacing: 20) {
        LinearLoader()
        LinearLoader(width: 48)
    }
    .padding()
}
