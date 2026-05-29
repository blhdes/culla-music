import SwiftUI

/// A single selectable sort option for a `SortChip` — one concrete
/// (field, direction) combination with a human-readable label. The concrete
/// enums (`PlaylistSortChoice`, `ArtistSortChoice`) conform to this so the chip
/// can render any of them with one generic implementation.
protocol SortChoiceProtocol: CaseIterable, Identifiable, Hashable {
    var label: String { get }
}

/// Compact glass capsule that opens a flat menu of sort options and shows the
/// active one inline ("⇅ Name (A→Z)"). Shared by the scope picker and the
/// playlists manager so both sheets sort with the exact same control.
///
/// The `.contentShape(.contextMenuPreview, Capsule())` matches the menu's
/// press-in "lift" silhouette to the glass capsule — without it iOS lifts the
/// label on a rectangular platter and the rounded ends render against raw,
/// unintegrated corners. (Same fix `MusicSwipeView` uses for its card menu.)
struct SortChip<Choice: SortChoiceProtocol>: View where Choice.AllCases: RandomAccessCollection {
    @Binding var selection: Choice

    var body: some View {
        Menu {
            Picker(selection: $selection) {
                ForEach(Choice.allCases) { choice in
                    Text(choice.label).tag(choice)
                }
            } label: {
                EmptyView()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.caption2.weight(.bold))
                Text(selection.label)
                    .font(.system(.caption, design: .rounded).weight(.medium))
                    .contentTransition(.opacity)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .opacity(0.6)
            }
            // Section headers uppercase their text; keep the chip's own casing.
            .textCase(nil)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .foregroundStyle(.secondary)
            .glassSurface(in: Capsule(), interactive: true)
            .contentShape(.contextMenuPreview, Capsule())
        }
        .animation(.snappy(duration: 0.2), value: selection)
    }
}
