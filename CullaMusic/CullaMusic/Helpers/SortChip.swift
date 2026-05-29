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
/// `.menuStyle(.button)` + `.buttonStyle(.plain)` are deliberate. A plain
/// `Menu` draws its own press chrome: a *rounded-rectangle* gray highlight plus
/// a lifted platter with a drop shadow. Both have square-ish corners that crop
/// against the capsule glass on touch — the "half-cut, badly integrated"
/// background. Routing the menu through a plain button style suppresses that
/// system chrome entirely, leaving only the flat capsule glass underneath. No
/// `interactive:` glass and no `.contextMenuPreview` reshaping needed once the
/// platter is gone — the chevron is affordance enough.
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
            .glassSurface(in: Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.2), value: selection)
    }
}
