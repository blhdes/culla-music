import SwiftUI
import UIKit

// MARK: - Marquee title

/// A single line of text that scrolls horizontally to reveal its full length
/// while `isActive` and the text is too wide to fit; otherwise it tail-
/// truncates like a normal line. Shared by the album sheet's now-playing track
/// row (left-aligned, scrolls only while playing) and the art carousel's
/// centred title (centre-aligned, always scrolls when it overflows) so a long
/// title can be read in full without the slot growing or the name staying
/// clipped. Honours Reduce Motion (stays truncated, never scrolls).
struct MarqueeText: View {
    let text: String
    /// The exact `UIFont` the row renders with — used both to draw the text and
    /// to measure its true width. Measuring straight from the font (instead of a
    /// hidden SwiftUI copy) is the whole point: a hidden view gets clamped to the
    /// column width and can never report an overflow, which is what silently
    /// stopped the scroll before.
    let uiFont: UIFont
    let color: Color
    let isActive: Bool
    /// How the text sits in its slot while it *fits* (truncating or shrink-to-
    /// fit). When it overflows and scrolls, the slide always starts from the
    /// leading edge regardless of this — so a centred title scrolls just like a
    /// left-aligned one once it's too long.
    var alignment: Alignment = .leading

    /// Drift speed in points per second — slow enough to read comfortably.
    private let speed: CGFloat = 30
    /// Beat held at the start before sliding, so the opening stays readable.
    private let edgePause: TimeInterval = 1.2
    /// Longer hold on the tail so the end of the title lingers before resetting.
    private let tailPause: TimeInterval = 2.0
    /// Soft cross-fade that hides the instant snap back to the start.
    private let fadeDuration: TimeInterval = 0.25
    /// A title that spills past the slot by no more than this many characters
    /// reads as "basically fits": on the playing row we shrink it a hair to show
    /// the whole thing instead of scrolling a pointless inch to reveal 2–3 chars.
    private let maxAbsorbableTrailChars: CGFloat = 3
    /// Floor for that shrink. A tiny trail needs only ~0.85–0.92, so 0.8 just
    /// bounds pathological cases — the text scales no further than it must to fit.
    private let trailFitFloor: CGFloat = 0.8

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    /// Faded to 0 only across the snap-back so the reset reads as a dissolve.
    @State private var scrollOpacity: Double = 1

    private var font: Font { Font(uiFont) }

    /// The text's true rendered width — a pure text measurement, so nothing in
    /// the layout can clamp it down to the visible column.
    private var textWidth: CGFloat {
        (text as NSString).size(withAttributes: [.font: uiFont]).width
    }

    /// How far the text spills past the visible slot.
    private var overflow: CGFloat { max(0, textWidth - containerWidth) }

    /// Width of "0" in the row's font — exact per-glyph on the monospaced track
    /// row, and a reasonable average for the proportional carousel title. It only
    /// sizes the "tiny trail" cutoff, so the approximation is harmless either way.
    private var characterWidth: CGFloat {
        ("0" as NSString).size(withAttributes: [.font: uiFont]).width
    }

    /// True when the title overflows by only a few characters — small enough to
    /// reveal in full by shrinking a hair instead of scrolling.
    private var trailIsTiny: Bool {
        overflow > 1 && overflow <= maxAbsorbableTrailChars * characterWidth
    }

    /// When active, a tiny trail shrinks to fit (full text, no ellipsis, no
    /// scroll) instead of sliding an inch to reveal 2–3 characters. Static, so
    /// it's fine under Reduce Motion too.
    private var shouldShrinkToFit: Bool {
        isActive && containerWidth > 1 && trailIsTiny
    }

    /// Scroll only an active, overflowing row that isn't in Reduce Motion, has
    /// been measured, and overflows by *more* than a tiny trail (those shrink to
    /// fit instead of scrolling).
    private var shouldScroll: Bool {
        isActive && !reduceMotion && containerWidth > 1 && overflow > 1 && !trailIsTiny
    }

    var body: some View {
        // A plain truncating copy defines the slot and its width — it never grows
        // the column, so the measured overflow stays put. When scrolling, that
        // copy goes invisible (but keeps its size) and a full-width copy floats
        // on top in an overlay; overlays can't resize their parent, so the slide
        // can't inflate the slot out from under itself.
        line
            .truncationMode(.tail)
            // A tiny trail on an active row scales down just enough to show the
            // whole title; every other state stays full-size (truncating or
            // scrolling exactly as before).
            .minimumScaleFactor(shouldShrinkToFit ? trailFitFloor : 1)
            .frame(maxWidth: .infinity, alignment: alignment)
            .opacity(shouldScroll ? 0 : 1)
            .background { containerMeasurer }
            .overlay(alignment: .leading) {
                if shouldScroll {
                    line
                        .fixedSize(horizontal: true, vertical: false)
                        .offset(x: offset)
                        .opacity(scrollOpacity)
                }
            }
            .clipped()
            // One declarative driver: restart the slide whenever the active
            // state or the measured overflow changes, settle back to 0 otherwise.
            .task(id: scrollKey) { await runScroll() }
    }

    private var line: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
    }

    /// Measures the visible slot so we know when the title overflows it.
    private var containerMeasurer: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { containerWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, w in containerWidth = w }
        }
    }

    // MARK: Animation

    /// Flips whenever the slide should reconfigure: encodes both *whether* we
    /// scroll and *how far*, so a re-measure restarts the loop cleanly while an
    /// idle row keeps a stable `-1`.
    private var scrollKey: Int {
        shouldScroll ? Int(overflow.rounded()) : -1
    }

    /// Loop the offset one way: hold at the start, slide to the far end, hold so
    /// the tail can be read, then fade out, snap back to 0 while invisible, fade
    /// in, and repeat. Driven by `.task(id:)`, so it auto-cancels on re-measure
    /// or disappear.
    private func runScroll() async {
        guard shouldScroll, overflow > 1 else {
            offset = 0
            scrollOpacity = 1
            return
        }
        offset = 0
        scrollOpacity = 1
        do {
            try await Task.sleep(for: .seconds(edgePause))
            while !Task.isCancelled {
                let distance = overflow
                guard distance > 1 else { break }
                let duration = TimeInterval(distance / speed)
                // Slide to the end and linger on the tail.
                withAnimation(.linear(duration: duration)) { offset = -distance }
                try await Task.sleep(for: .seconds(duration + tailPause))
                // Fade out, snap back to the start unseen, fade in, then hold.
                withAnimation(.easeInOut(duration: fadeDuration)) { scrollOpacity = 0 }
                try await Task.sleep(for: .seconds(fadeDuration))
                offset = 0
                withAnimation(.easeInOut(duration: fadeDuration)) { scrollOpacity = 1 }
                try await Task.sleep(for: .seconds(fadeDuration + edgePause))
            }
        } catch {
            // Cancelled (re-measure / view gone) — the next task or the guard
            // above settles the offset; nothing to do here.
        }
    }
}
