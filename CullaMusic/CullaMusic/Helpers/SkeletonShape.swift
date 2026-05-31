import SwiftUI

/// A single placeholder "bone" for skeleton loading states: a filled shape with
/// a soft highlight sweeping across it. Build a skeleton by laying these out in
/// the same geometry as the real content, so the reveal reads as the layout
/// *sharpening into focus* rather than a spinner popping into a finished screen.
///
/// The sweep is driven by a shared `TimelineView` clock, so several bones laid
/// out together stay phase-synced — at any instant their highlights sit at the
/// same fraction across, reading as one coordinated shimmer.
///
/// Respects `accessibilityReduceMotion`: when on, the sweep is dropped entirely
/// and the bone renders as a calm static placeholder (freeze, don't slow —
/// motion was explicitly opted out of).
struct SkeletonShape<S: Shape>: View {
    let shape: S
    var fill: Color = .primary.opacity(0.10)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        shape
            .fill(fill)
            .overlay {
                if !reduceMotion {
                    TimelineView(.animation) { timeline in
                        SweepHighlight(phase: Self.phase(at: timeline.date))
                    }
                    // Clip the full-bleed sweep to this bone's own shape so the
                    // highlight shows at full strength inside crisp (rounded)
                    // edges — masking by the fill's alpha would dim it instead.
                    .clipShape(shape)
                    .allowsHitTesting(false)
                }
            }
    }

    /// 0→1 ramp on a 1.5s loop. The band is offscreen at both 0 and 1, so the
    /// wrap from 1→0 is invisible.
    private static func phase(at date: Date) -> Double {
        let period = 1.5
        let t = date.timeIntervalSinceReferenceDate
        return (t.truncatingRemainder(dividingBy: period)) / period
    }
}

/// A soft white band that travels left→right across its container, lightening
/// whatever sits beneath it via `.plusLighter` (works in both light and dark).
private struct SweepHighlight: View {
    let phase: Double

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let band = max(w * 0.45, 60)
            LinearGradient(
                colors: [.clear, .white.opacity(0.5), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: band)
            // Start fully off the leading edge, end fully off the trailing edge.
            .offset(x: -band + (w + band) * phase)
            .blendMode(.plusLighter)
        }
    }
}

// MARK: - SkeletonRow

/// A minimal list-row skeleton: a leading thumbnail/avatar bone plus stacked
/// title/subtitle bones, sized to match the app's standard song / playlist /
/// artist rows. Compose a loading state by stacking a few of these (see
/// `SkeletonRows`) so the reveal reads as the list *sharpening into focus*
/// rather than a spinner sitting on empty space.
///
/// Every bone is its own `SkeletonShape`, so they all read the same shared
/// clock and shimmer in phase — the row looks like one coordinated sweep.
struct SkeletonRow: View {
    /// Leading bone shape — square-ish cover (`rounded`) or circular avatar.
    enum Lead {
        case rounded(CGFloat)
        case circle
    }

    var lead: Lead = .rounded(10)
    var leadSize: CGFloat = 52
    var titleWidth: CGFloat = 150
    /// `nil` collapses the row to a single line (artist rows have no subtitle).
    var subtitleWidth: CGFloat? = 90
    /// A short bone pinned to the trailing edge — e.g. a track-count badge.
    var showsTrailing: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            leadBone

            VStack(alignment: .leading, spacing: 7) {
                SkeletonShape(shape: Capsule())
                    .frame(width: titleWidth, height: 11)
                if let subtitleWidth {
                    SkeletonShape(shape: Capsule())
                        .frame(width: subtitleWidth, height: 9)
                }
            }

            Spacer(minLength: 8)

            if showsTrailing {
                SkeletonShape(shape: Capsule())
                    .frame(width: 24, height: 11)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var leadBone: some View {
        switch lead {
        case .rounded(let radius):
            SkeletonShape(shape: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .frame(width: leadSize, height: leadSize)
        case .circle:
            SkeletonShape(shape: Circle())
                .frame(width: leadSize, height: leadSize)
        }
    }
}

// MARK: - SkeletonRows

/// A short run of `SkeletonRow`s with gently varied title widths so the
/// placeholder reads as real, uneven content instead of a repeated stamp.
/// Drop it straight inside a `List` section (or `ManagePlaylistsSheet`'s
/// loading row) — it emits the rows, the caller owns the surrounding `List`.
struct SkeletonRows: View {
    var count: Int = 6
    var lead: SkeletonRow.Lead = .rounded(10)
    var leadSize: CGFloat = 52
    var subtitle: Bool = true
    var showsTrailing: Bool = false

    // Deterministic width jitter keyed by index — stable across frames so the
    // rows never reflow while shimmering.
    private let titleWidths: [CGFloat] = [168, 132, 184, 120, 150, 142, 176, 128]
    private let subtitleWidths: [CGFloat] = [96, 78, 110, 70, 90, 84, 102, 74]

    var body: some View {
        ForEach(0..<count, id: \.self) { index in
            SkeletonRow(
                lead: lead,
                leadSize: leadSize,
                titleWidth: titleWidths[index % titleWidths.count],
                subtitleWidth: subtitle ? subtitleWidths[index % subtitleWidths.count] : nil,
                showsTrailing: showsTrailing
            )
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        SkeletonShape(shape: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .frame(width: 220, height: 220)
        SkeletonRow()
        SkeletonRow(lead: .circle, leadSize: 44, subtitleWidth: nil, showsTrailing: true)
    }
    .padding(40)
}
