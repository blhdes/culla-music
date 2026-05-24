import SwiftUI

/// Sheet for picking the app accent. The rainbow of 13 swatches lives here
/// instead of always-on in Settings so the Settings page can stay calm — the
/// grid is meaningful as a destination, not as decoration.
///
/// Single-section sheet: no section-card chrome. The nav title "Accent Color"
/// carries identity; the grid sits directly on `Color(.systemBackground)` to
/// match the Settings parent's calm utility surface.
struct AccentPalettePickerSheet: View {
    @Binding var selectedRaw: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 56), spacing: 18)],
                    alignment: .leading,
                    spacing: 18
                ) {
                    ForEach(AccentPalette.allCases) { palette in
                        swatch(palette)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 20)
            }
            .scrollContentBackground(.hidden)
            .background(Color(.systemBackground))
            .navigationTitle("Accent Color")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    @ViewBuilder
    private func swatch(_ palette: AccentPalette) -> some View {
        let isSelected = selectedRaw == palette.rawValue
        Button {
            withAnimation(.snappy(duration: 0.22)) {
                selectedRaw = palette.rawValue
            }
        } label: {
            VStack(spacing: 8) {
                Circle()
                    .fill(palette.color)
                    .frame(width: 38, height: 38)
                    .overlay {
                        Circle()
                            .stroke(.primary, lineWidth: isSelected ? 2 : 0)
                            .padding(-4)
                    }
                Text(palette.label)
                    .font(.system(.caption2, design: .rounded).weight(.medium))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(palette.label)
    }
}

#Preview {
    AccentPalettePickerSheet(selectedRaw: .constant(AccentPalette.blue.rawValue))
        .environment(\.appAccent, .blue)
}
