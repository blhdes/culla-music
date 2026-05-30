import SwiftUI

/// A single selectable sort option for a `SortChip` — one concrete
/// (field, direction) combination with a human-readable label. The concrete
/// enums (`PlaylistSortChoice`, `ArtistSortChoice`) conform to this so the chip
/// can render any of them with one generic implementation.
protocol SortChoiceProtocol: CaseIterable, Identifiable, Hashable {
    var label: String { get }
}

/// Compact glass icon button that opens a flat menu of sort options. Shared by
/// the scope picker and the playlists manager so both sheets sort with the
/// exact same control.
///
/// **Icon-only on purpose.** The chip used to show the active label inline
/// ("⇅ Name (A→Z)"), but the labels are different lengths, so picking a new
/// sort resized the chip — and that width change flickered. A fixed-size icon
/// can't resize, so the flicker is gone. The current selection still reaches
/// VoiceOver via `accessibilityValue`, and the open menu shows a checkmark on
/// the active row, so nothing is actually lost.
///
/// **Press chrome.** A `Menu` with a custom label makes iOS draw its own lift
/// platter on touch (a rounded-rectangle + shadow that morphs into the menu).
/// Under a non-rectangular shape it crops at the corners. The fix is to let the
/// system own the glass: on iOS 26 the native `.glass` button style + a
/// `.circle` border shape means the button *is* the glass, so iOS morphs that
/// exact circle into the menu — no separate platter to crop. Pre-26 falls back
/// to a flat `.thinMaterial` circle.
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
            Image(systemName: "arrow.up.arrow.down")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
        }
        .modifier(SortChipChrome())
        .accessibilityLabel("Sort")
        .accessibilityValue(selection.label)
    }
}

/// Applies the menu/button chrome that suppresses iOS's lift platter, branching
/// on OS so the iOS 26 glass morph is used where available and a flat circle
/// fallback elsewhere.
private struct SortChipChrome: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .menuStyle(.button)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.small)
                // Keep the interactive glass neutral, not accent-tinted —
                // matches the app's restrained-accent treatment on chrome.
                .tint(.secondary)
        } else {
            content
                .menuStyle(.button)
                .buttonStyle(.plain)
                .padding(8)
                .background(.thinMaterial, in: Circle())
        }
    }
}
