import SwiftUI

/// Date-jump affordance for add-date timelines. It's a fast scrubber: pick a
/// month and the surface it lives on snaps to that point in your add-date
/// history. Shown in two places, with the same look and copy:
/// - On the **expanded carousel** (`HomeArtCarouselView`), under the method
///   selector — picking a date scrolls the carousel and the session starts there
///   (Library / Unsorted only).
/// - In the **swipe session** (`MusicSwipeView`), as a top-center pill (opt-in
///   via Settings) — picking a date rebuilds the deck from that point, for the
///   Library, Unsorted, or an artist session (scoped to that artist's add-dates).
/// Hidden in Dismissed (sorted by dismissal date) and for playlist sessions
/// (ordered by playlist position, no usable per-track add-date), and when no
/// add-dates are available.
///
/// Deliberately mirrors `CarouselIdentityStrip`'s vocabulary — same glass
/// capsule, icon → short label → chevron, same paddings and stroke — so on the
/// carousel the two read as a stacked, aligned pair (method on top, date beneath).
///
/// Two pieces:
/// - `DateJumpControl` — the capsule (icon + short date + chevron).
/// - `DateJumpSheet` — a minimalist wheel picker (no calendar grid).
struct DateJumpControl: View {
    /// Add-date currently anchored — the centred carousel cover, or the current
    /// swipe card. Tracks live, and is where the session starts/continues.
    /// Shown short ("Jun 1, 2024").
    let displayDate: Date
    /// True while a far jump pages toward its target — swaps the calendar glyph
    /// for a spinner so a multi-second jump reads as working.
    let isJumping: Bool
    let onOpen: () -> Void

    /// Built once rather than per body pass — the pill re-renders on every
    /// carousel scroll tick (it live-tracks the centred cover), so rebuilding
    /// the format style each time would allocate on a hot path. Locale stays
    /// dynamic: `.formatted` resolves it at call time.
    private static let dateLabelStyle = Date.FormatStyle.dateTime
        .day().month(.abbreviated).year()

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
                }

                Text(displayDate.formatted(Self.dateLabelStyle))
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
        // Override the composed icon/chevron readout with one clear control
        // label; the value carries the anchored date (or the jump state).
        .accessibilityLabel("Jump to a date")
        .accessibilityValue(isJumping ? "Jumping" : displayDate.formatted(Self.dateLabelStyle))
    }
}

/// Minimalist wheel date picker bounded to the session's add-date span (the
/// whole library, or a single artist) — a spinning month/day/year wheel rather
/// than a full graphical calendar, kept in a short sheet. Same glass-sheet
/// family (NavigationStack + inline title + Cancel/confirm toolbar) as
/// `SourceScopePickerSheet`.
struct DateJumpSheet: View {
    let onConfirm: (Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccent) private var appAccent
    /// Normalised once in `init` so an inverted span can't crash the
    /// `DatePicker(in:)` ClosedRange downstream.
    private let dateRange: ClosedRange<Date>
    @State private var selection: Date

    init(lowerBound: Date, upperBound: Date, initialDate: Date, onConfirm: @escaping (Date) -> Void) {
        self.onConfirm = onConfirm
        // Callers pass (oldest, newest), but order defensively — a ClosedRange
        // with lowerBound > upperBound is a hard crash, not a clamp.
        let range = min(lowerBound, upperBound)...max(lowerBound, upperBound)
        self.dateRange = range
        // Clamp into the valid span so the wheel never opens on an out-of-range
        // day (e.g. the centred song's date sitting outside a 1-day span).
        _selection = State(initialValue: min(max(initialDate, range.lowerBound), range.upperBound))
    }

    var body: some View {
        NavigationStack {
            DatePicker(
                "Start date",
                selection: $selection,
                in: dateRange,
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
