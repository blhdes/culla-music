import SwiftUI
import SwiftData
import MusicKit

/// A reverse-chronological timeline of past movements — songs sorted into a
/// playlist (or loved) and songs dismissed. Swipe a row to undo: a sort is
/// pulled from its playlist (Apple Music too), a dismissal is forgotten. The
/// row animates out on undo.
///
/// Uses a plain `.insetGrouped` List so the native `.swipeActions` gesture is
/// the row interaction — same flicker-free presentation the playlist sheets
/// settled on. Personality comes from the rounded type, the colored movement
/// labels, and the glass toast, not a hand-built surface stack.
struct HistorySheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccent) private var appAccent
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Namespace so the undo toast crystallizes (materializes) inside its stable
    /// container on iOS 26 rather than only sliding up. Inert below iOS 26.
    @Namespace private var glassMorph

    @State private var store: HistoryStore?
    @State private var toastTimer: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Group {
                if let store {
                    content(store)
                } else {
                    loadingState
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task {
            guard store == nil else { return }
            let store = HistoryStore(modelContext: modelContext)
            self.store = store
            await store.load()
        }
    }

    @ViewBuilder
    private func content(_ store: HistoryStore) -> some View {
        if store.isLoading {
            loadingState
        } else if store.isEmpty {
            emptyState
        } else {
            timeline(store)
        }
    }

    private func timeline(_ store: HistoryStore) -> some View {
        List {
            ForEach(store.sections) { section in
                Section {
                    ForEach(section.entries) { entry in
                        HistoryRow(entry: entry, isResolving: store.isResolving)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                rowAction(for: entry, store: store)
                            }
                    }
                } header: {
                    Text(section.title)
                        .textCase(nil)
                        .font(.system(.footnote, design: .rounded).weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .animation(.snappy(duration: 0.28), value: store.entries.map(\.id))
        .overlay(alignment: .bottom) {
            // Stable container outside the `if` so the toast materializes as
            // glass inside it on iOS 26 rather than only sliding up.
            GlassStack(spacing: 0) {
                if let toast = store.toast {
                    toastPill(toast)
                        .padding(.bottom, 28)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: store.toast)
        .onChange(of: store.toast) { _, message in
            guard message != nil else { return }
            toastTimer?.cancel()
            toastTimer = Task {
                try? await Task.sleep(for: .seconds(1.8))
                guard !Task.isCancelled else { return }
                store.toast = nil
            }
        }
    }

    /// The trailing swipe action for a row. Culla-created sorts (and every
    /// dismissal) get a true "Undo" — it reverses locally *and* removes the
    /// track from Apple Music. Sorts into the user's OWN playlists can't be
    /// removed via the API (`MusicLibrary.shared.edit` only edits app-created
    /// playlists), so rather than a half-true undo we hand off to the Music app,
    /// where the user can remove the track themselves. A row with no playlist id
    /// falls back to the honest undo so the action is never a dead button.
    @ViewBuilder
    private func rowAction(for entry: HistoryStore.Entry, store: HistoryStore) -> some View {
        if entry.isStale {
            // Phantom log entry — the song already left the playlist (removed in
            // Music). Nothing to undo or open; the row stays purely as a record.
            EmptyView()
        } else if case .sorted(_, _, let createdByApp) = entry.movement, !createdByApp {
            // Culla can't remove from the user's own playlists, and Apple exposes
            // no deep link to a private playlist — so we just open the Music app
            // and let them remove the track there. Reconciliation then greys this
            // row and frees the song to re-sort.
            Button {
                Haptics.tap()
                openURL(Self.appleMusicAppURL)
            } label: {
                Label("Open in Music", systemImage: "arrow.up.right.square")
            }
            .tint(appAccent)
        } else {
            Button {
                Haptics.undo()
                Task { await store.undo(entry) }
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .tint(appAccent)
        }
    }

    /// Apple exposes no public URL for a user's private library playlist (a
    /// catalog-style link just errors with "not available in your region"), so
    /// "Open in Music" only launches the Music app — the user navigates to the
    /// playlist themselves.
    private static let appleMusicAppURL = URL(string: "music://")!

    // MARK: - States

    private var loadingState: some View {
        // A skeleton list rather than a spinner — the placeholder rows occupy
        // the same geometry as the timeline, so the load reads as the list
        // sharpening into focus.
        List {
            Section {
                SkeletonRows(count: 7)
            }
        }
        .listStyle(.insetGrouped)
        .allowsHitTesting(false)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No history yet", systemImage: "clock.arrow.circlepath")
        } description: {
            Text("Songs you sort or dismiss show up here, newest first.")
        }
    }

    private func toastPill(_ text: String) -> some View {
        Text(text)
            .font(.system(.subheadline, design: .rounded).weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassSurface(in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.22), radius: 12, y: 5)
            .glassMorphID("history.toast", in: glassMorph)
            .glassMorphTransition(.materialize, reduceMotion: reduceMotion)
    }
}

// MARK: - Row

private struct HistoryRow: View {
    let entry: HistoryStore.Entry
    let isResolving: Bool

    @Environment(\.appAccent) private var appAccent

    var body: some View {
        HStack(spacing: 12) {
            artwork

            VStack(alignment: .leading, spacing: isPlaceholder ? 7 : 3) {
                if isPlaceholder {
                    // Only the song identity is unknown — the movement tag and
                    // time below come straight from the saved record, so they
                    // stay solid while the title/artist shimmer in.
                    SkeletonShape(shape: Capsule()).frame(width: 150, height: 11)
                    SkeletonShape(shape: Capsule()).frame(width: 92, height: 9)
                } else {
                    Text(entry.song?.title ?? "Track unavailable")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(entry.song?.artistName ?? "No longer in your library")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                movementLabel
                    .padding(.top, 1)
            }

            Spacer(minLength: 8)

            Text(PlaylistMembershipChips.relativeAge(from: entry.date))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        // Phantom log entry — the song left the playlist (removed in Music), so
        // the row recedes but stays as a record of what once happened.
        .opacity(entry.isStale ? 0.5 : 1)
    }

    @ViewBuilder
    private var artwork: some View {
        if isPlaceholder {
            SkeletonShape(shape: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .frame(width: 52, height: 52)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.quaternary)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    )
                if let artwork = entry.song?.artwork {
                    ArtworkImage(artwork, width: 52, height: 52)
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private var movementLabel: some View {
        switch entry.movement {
        case .sorted(let playlistName, let loved, _):
            if loved {
                label(icon: "heart.fill", text: "Loved", color: .pink)
            } else {
                label(icon: "text.badge.plus", text: playlistName, color: appAccent)
            }
        case .dismissed:
            label(icon: "xmark", text: "Dismissed", color: .red)
        }
    }

    private func label(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2.weight(.bold))
            Text(text)
                .font(.caption.weight(.medium))
                .strikethrough(entry.isStale)
                .lineLimit(1)
        }
        .foregroundStyle(color)
    }

    // While the library walk is in flight a nil song means "still resolving" →
    // show skeleton bones. Once it's done, a nil song means the track was
    // removed from the library, so the row falls back to "Track unavailable".
    private var isPlaceholder: Bool {
        entry.song == nil && isResolving
    }
}
