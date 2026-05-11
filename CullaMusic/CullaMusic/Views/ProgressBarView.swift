import SwiftUI

/// Hairline scrubbable progress bar drawn on top of the artwork.
/// The parent owns `scrubOverride` so the time labels below the artwork
/// can mirror the user's drag in real time.
struct ProgressBarView: View {
    let position: TimeInterval
    let duration: TimeInterval
    @Binding var scrubOverride: TimeInterval?
    let onSeek: (TimeInterval) -> Void

    @Environment(\.appAccent) private var accent

    private var displayedPosition: TimeInterval {
        scrubOverride ?? position
    }

    private var progress: CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(min(max(displayedPosition / duration, 0), 1))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.35))
                Capsule()
                    .fill(accent)
                    .frame(width: max(geo.size.width * progress, 0))
            }
            .frame(height: 1.5)
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(scrubGesture(width: geo.size.width))
        }
        .frame(height: 22)
    }

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if scrubOverride == nil {
                    Haptics.scrubTick()
                }
                let ratio = max(0, min(value.location.x / max(width, 1), 1))
                scrubOverride = Double(ratio) * duration
            }
            .onEnded { _ in
                let target = scrubOverride ?? displayedPosition
                onSeek(target)
                Haptics.scrubTick()
                scrubOverride = nil
            }
    }
}
