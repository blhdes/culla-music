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
            let scrubbing = scrubOverride != nil
            let dotSize: CGFloat = scrubbing ? 12 : 8
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.35))
                Capsule()
                    .fill(accent)
                    .frame(width: max(geo.size.width * progress, 0))
                    // A progress/scrub fill should track the live position
                    // exactly — never ease its width. Without this, when the
                    // parent fades the bar out on pause (`progressOpacity`'s
                    // 0.35s animation), that same transaction also tweens the
                    // fill's width down to zero, so the colored bar visibly
                    // retracts toward the left as it disappears. Pinning the
                    // width change to no animation makes it snap to its value
                    // while only the opacity fades.
                    .animation(nil, value: progress)

                // Playhead dot — marks the exact spot in the song. White with a
                // soft shadow so it reads on both the accent fill and the bare
                // track, and grows a touch while scrubbing for a clearer grab
                // target. Centred vertically on the hairline (the ZStack's
                // vertical alignment) and offset to the live position.
                Circle()
                    .fill(.white)
                    .frame(width: dotSize, height: dotSize)
                    .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 0.5)
                    .offset(x: max(geo.size.width * progress - dotSize / 2, 0))
                    // Position tracks the playhead un-animated (same reasoning as
                    // the fill); only the grow-on-scrub size springs.
                    .animation(nil, value: progress)
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: scrubbing)
            }
            .frame(height: 1.5)
            // Anchor the hairline to the bottom of the expanded touch frame
            // (with a small inset so it lands at roughly the same visual
            // position as before) — extra height grows *upward* into the
            // artwork as pure hit area.
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 10)
            .contentShape(Rectangle())
            // Must be `simultaneousGesture`, NOT `highPriorityGesture`: the card
            // stack above attaches its drag with `.highPriorityGesture`, and a
            // *parent's* high-priority gesture wins over a child's — so a child
            // high-priority scrub never fired and every scrub swiped the card.
            // Recognising simultaneously lets the scrub fire alongside the card
            // drag; because it uses `minimumDistance: 0` it lands on touch-down,
            // before the card drag's threshold, so MusicSwipeView sees the
            // scrub start and pins the card before it can move.
            .simultaneousGesture(scrubGesture(width: geo.size.width))
        }
        .frame(height: 44)
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
