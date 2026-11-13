import SwiftUI

// MARK: - ModeChipRow

/// Home's compact mode picker: Library, Unsorted and Dismissed as one row of
/// three chips (icon + count on top, title below). A title is never cut off
/// with "…". The row picks the first of these that fits the screen width:
///
/// 1. Three equal chips, titles on one line (most languages and phones).
/// 2. Chips sized to their titles, still one line (a long word such as
///    French "Bibliothèque" gets the room it needs on a small iPhone).
/// 3. Same, with multi-word titles broken between words onto two lines
///    (Portuguese "Não organizadas").
/// 4. Today's full-width `ModeTile` rows, for very large text sizes.
///
/// `ViewThatFits` compares each option's natural width with the space it is
/// offered, so this follows the real fonts, the language and Dynamic Type
/// with no measuring code of our own.
struct ModeChipRow: View {
    let selectedMode: ReviewMode
    let count: (ReviewMode) -> Int?
    let isLoadingCount: (ReviewMode) -> Bool
    let onSelect: (ReviewMode) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            chips(twoLineTitles: false)
            chips(twoLineTitles: true)
            GlassStack(spacing: 10) {
                ForEach(ReviewMode.allCases) { mode in
                    ModeTile(
                        mode: mode,
                        isSelected: selectedMode == mode,
                        count: count(mode),
                        isLoadingCount: isLoadingCount(mode)
                    ) {
                        onSelect(mode)
                    }
                }
            }
        }
    }

    private func chips(twoLineTitles: Bool) -> some View {
        GlassStack(spacing: 8) {
            ChipRowLayout(spacing: 8) {
                ForEach(ReviewMode.allCases) { mode in
                    ModeChip(
                        mode: mode,
                        isSelected: selectedMode == mode,
                        count: count(mode),
                        isLoadingCount: isLoadingCount(mode),
                        twoLineTitle: twoLineTitles
                    ) {
                        onSelect(mode)
                    }
                }
            }
        }
    }
}

// MARK: - ChipRowLayout

/// Lays the chips out in one row that fills the offered width, all the same
/// height. Equal widths when the widest chip fits a third of the row;
/// otherwise each chip gets its natural width plus an equal share of what's
/// left. Its natural width (what `ViewThatFits` checks) is the sum of the
/// chips' natural widths, so the row only "fits" when no title gets cut.
private struct ChipRowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideals = idealWidths(subviews)
        let width = proposal.width ?? (ideals.reduce(0, +) + totalSpacing(subviews))
        let widths = columnWidths(for: width, ideals: ideals)
        return CGSize(width: width, height: rowHeight(subviews, widths: widths))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = columnWidths(for: bounds.width, ideals: idealWidths(subviews))
        let height = rowHeight(subviews, widths: widths)
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths) {
            subview.place(
                at: CGPoint(x: x, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: width, height: height)
            )
            x += width + spacing
        }
    }

    private func totalSpacing(_ subviews: Subviews) -> CGFloat {
        spacing * CGFloat(max(subviews.count - 1, 0))
    }

    private func idealWidths(_ subviews: Subviews) -> [CGFloat] {
        subviews.map { $0.sizeThatFits(.unspecified).width }
    }

    private func columnWidths(for totalWidth: CGFloat, ideals: [CGFloat]) -> [CGFloat] {
        guard !ideals.isEmpty else { return [] }
        let count = CGFloat(ideals.count)
        let available = max(totalWidth - spacing * (count - 1), 0)
        let equal = available / count
        if let widest = ideals.max(), widest <= equal {
            return Array(repeating: equal, count: ideals.count)
        }
        let natural = ideals.reduce(0, +)
        let extra = (available - natural) / count
        // `extra` is only negative if this row was forced into too little
        // room, which `ViewThatFits` avoids. Shrink proportionally then.
        guard extra < 0 else { return ideals.map { $0 + extra } }
        return ideals.map { $0 * available / max(natural, 1) }
    }

    private func rowHeight(_ subviews: Subviews, widths: [CGFloat]) -> CGFloat {
        zip(subviews, widths)
            .map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }
            .max() ?? 0
    }
}

// MARK: - ModeChip

/// One compact mode chip. Same look as `ModeTile`: glass when unselected, a
/// solid accent fill with contrast-aware text when selected, no accent halo.
/// The tile's one-line description moves to the VoiceOver hint.
private struct ModeChip: View {
    let mode: ReviewMode
    let isSelected: Bool
    let count: Int?
    let isLoadingCount: Bool
    let twoLineTitle: Bool
    let onTap: () -> Void

    @Environment(\.appAccent) private var appAccent
    @ScaledMetric(relativeTo: .subheadline) private var titleSize: CGFloat = 14
    @ScaledMetric(relativeTo: .subheadline) private var iconSize: CGFloat = 15

    private let radius: CGFloat = 16
    private var accentForeground: Color { appAccent.idealForeground }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: mode.icon)
                        .font(.system(size: iconSize, weight: .semibold))
                        .symbolEffect(.bounce, value: isSelected)
                    Spacer(minLength: 0)
                    countSlot
                }
                .foregroundStyle(isSelected ? accentForeground : .secondary)

                Text(twoLineTitle ? Self.splitBetweenWords(mode.title) : mode.title)
                    .font(.system(size: titleSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(isSelected ? accentForeground : .primary)
                    .lineLimit(twoLineTitle ? 2 : 1)
                    .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 11)
            // Fill whatever width/height the row hands out, top-aligned, so
            // every chip is the same height and the titles start on one line.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(LinearGradient(
                            colors: [appAccent, appAccent.opacity(0.85)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .glassSurface(
                in: RoundedRectangle(cornerRadius: radius, style: .continuous),
                interactive: true
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        isSelected ? .white.opacity(0.20) : .white.opacity(0.06),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityHint(mode.description)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(.spring(response: 0.4, dampingFraction: 0.78), value: isSelected)
    }

    @ViewBuilder
    private var countSlot: some View {
        Group {
            if isLoadingCount {
                // Same shimmering bone as `ModeTile`, sized for the chip.
                SkeletonShape(
                    shape: Capsule(),
                    fill: isSelected ? accentForeground.opacity(0.28) : .primary.opacity(0.10)
                )
                .frame(width: 30, height: 13)
            } else if let count {
                Text(count.formatted())
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .contentTransition(.numericText(countsDown: true))
            }
        }
        .animation(.snappy, value: count)
    }

    /// Puts a line break at the space closest to the middle, so a two-word
    /// title wraps between words ("Não / organizadas") instead of mid-word.
    /// One-word titles come back unchanged.
    static func splitBetweenWords(_ title: String) -> String {
        let spaces = title.indices.filter { title[$0] == " " }
        let middle = title.count / 2
        guard let split = spaces.min(by: {
            abs(title.distance(from: title.startIndex, to: $0) - middle)
                < abs(title.distance(from: title.startIndex, to: $1) - middle)
        }) else { return title }
        var result = title
        result.replaceSubrange(split...split, with: "\n")
        return result
    }
}
