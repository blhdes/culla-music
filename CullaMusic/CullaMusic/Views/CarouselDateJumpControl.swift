import SwiftUI

/// Date-jump affordance shown directly under the carousel's method selector
/// (`CarouselIdentityStrip`) for the Library / Unsorted timelines. The carousel
/// IS the add-date timeline, so this is a fast scrubber: pick a month and the
/// carousel snaps to a cover you added around then (nothing is removed — you
/// can still flick before/after it). The picked date then flows into the swipe
/// session so the whole session sorts from there. Hidden in Dismissed and when
/// no add-dates are available.
///
/// Deliberately mirrors `CarouselIdentityStrip`'s vocabulary — same glass
/// capsule, icon → short label → chevron, same paddings and stroke — so the two
/// read as a stacked, aligned pair (method on top, date beneath it).
///
/// Two pieces:
/// - `CarouselDateJumpControl` — the capsule (icon + short date + chevron).
/// - `CarouselDateJumpSheet` — a minimalist wheel picker (no calendar grid).
struct CarouselDateJumpControl: View {
    /// Add-date of the cover currently centred in the carousel — tracks the
    /// scroll live, and is where the session starts. Shown short ("Jun 1, 2024").
    let displayDate: Date
    /// True while `loadUntil` pages toward a far date — swaps the calendar
    /// glyph for a spinner so a multi-second jump reads as working.
    let isJumping: Bool
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                if isJumping {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.secondary)
                } else {
                    Image(systemName: "calendar")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .contentTransition(.symbolEffect(.replace))
                }

                Text(displayDate.formatted(.dateTime.day().month(.abbreviated).year()))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(1.0)
                    .textCase(.uppercase)
                    .foregroundStyle(.primary)
                    .contentTransition(.opacity)

                // Same "this opens a picker" affordance the identity strip uses
                // for its Menu, so the pair reads consistently.
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Capsule())
            .glassSurface(in: Capsule(), interactive: true)
            .overlay(
                Capsule()
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isJumping)
        .animation(.snappy(duration: 0.2), value: isJumping)
    }
}

/// Minimalist wheel date picker bounded to the library's add-date span — a
/// spinning month/day/year wheel rather than a full graphical calendar, kept
/// in a short sheet. Same glass-sheet family (NavigationStack + inline title +
/// Cancel/confirm toolbar) as `SourceScopePickerSheet`.
struct CarouselDateJumpSheet: View {
    let lowerBound: Date
    let upperBound: Date
    let initialDate: Date
    let onConfirm: (Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccent) private var appAccent
    @State private var selection: Date

    init(lowerBound: Date, upperBound: Date, initialDate: Date, onConfirm: @escaping (Date) -> Void) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.initialDate = initialDate
        self.onConfirm = onConfirm
        // Clamp into the valid span so the wheel never opens on an out-of-range
        // day (e.g. the centred song's date sitting outside a 1-day span).
        _selection = State(initialValue: min(max(initialDate, lowerBound), upperBound))
    }

    var body: some View {
        NavigationStack {
            DatePicker(
                "Start date",
                selection: $selection,
                in: lowerBound...upperBound,
                displayedComponents: .date
            )
            .datePickerStyle(.wheel)
            .labelsHidden()
            .tint(appAccent)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Jump to a date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Jump") {
                        onConfirm(selection)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.height(320)])
        .presentationDragIndicator(.visible)
    }
}
