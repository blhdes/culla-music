import SwiftUI
import MusicKit

/// Sheet for picking a scope to sort from — a playlist, an artist, or
/// "All Library". The segmented control at the top swaps between the two
/// scoped lists; selecting "All Library" works from either tab.
struct SourceScopePickerSheet: View {
    let playlists: [Playlist]
    let selectedScope: SourceScope?
    let onPick: (SourceScope?) -> Void   // nil → All Library

    @Environment(\.dismiss) private var dismiss

    /// Per-playlist track counts loaded from the persisted membership index.
    /// HomeView has no live `MembershipIndex`, so we read the on-disk snapshot
    /// the swipe screen writes after each rebuild/swipe.
    @State private var trackCounts: [String: Int] = [:]
    @State private var libraryArtists: [Artist] = []
    @State private var isLoadingArtists: Bool = false
    @State private var pickerMode: PickerMode = .playlists

    enum PickerMode: String, CaseIterable, Identifiable {
        case playlists
        case artists

        var id: String { rawValue }
        var label: String { self == .playlists ? "Playlists" : "Artists" }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Scope", selection: $pickerMode) {
                    ForEach(PickerMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                listBody
            }
            .navigationTitle("Sort From")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                if trackCounts.isEmpty {
                    trackCounts = await Task.detached(priority: .userInitiated) {
                        MembershipIndex.diskCountsSnapshot()
                    }.value
                }
            }
            .onAppear {
                // Seed the segmented control to the user's existing pick so
                // re-opening the sheet doesn't snap them back to Playlists.
                if case .artist = selectedScope { pickerMode = .artists }
            }
        }
    }

    // MARK: - Lists

    @ViewBuilder
    private var listBody: some View {
        switch pickerMode {
        case .playlists: playlistsList
        case .artists:   artistsList
        }
    }

    private var playlistsList: some View {
        List {
            Section {
                libraryRow
            } footer: {
                Text("Pick a playlist to sort songs from, or use your full library.")
            }

            if !playlists.isEmpty {
                Section("Playlists") {
                    ForEach(playlists, id: \.id) { playlist in
                        playlistRow(playlist)
                    }
                }
            }
        }
    }

    private var artistsList: some View {
        List {
            Section {
                libraryRow
            } footer: {
                Text("Pick an artist to swipe through their tracks in your library.")
            }

            if isLoadingArtists && libraryArtists.isEmpty {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
            } else if !libraryArtists.isEmpty {
                Section("Artists") {
                    ForEach(libraryArtists, id: \.id) { artist in
                        artistRow(artist)
                    }
                }
            }
        }
        .task {
            await loadArtistsIfNeeded()
        }
    }

    private func loadArtistsIfNeeded() async {
        guard libraryArtists.isEmpty, !isLoadingArtists else { return }
        isLoadingArtists = true
        defer { isLoadingArtists = false }
        do {
            let artists = try await MusicLibraryService.shared.refreshLibraryArtists()
            libraryArtists = artists.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        } catch {
            print("SourceScopePickerSheet.loadArtists failed: \(error)")
        }
    }

    // MARK: - Rows

    private var libraryRow: some View {
        let isSelected = selectedScope == nil
        return Button {
            onPick(nil)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Rectangle()
                    .fill(.quaternary)
                    .overlay(
                        Image(systemName: "music.note.list")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    )
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                Text("All Library")
                    .foregroundStyle(.primary)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .font(.body.weight(.semibold))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Track count to show, or nil to omit the badge. Editable playlists are
    /// always walked, so a missing key means a true zero. Read-only playlists
    /// may be skipped when the curated toggle is off — in that case we'd rather
    /// show nothing than lie with "0".
    private func displayCount(for playlist: Playlist) -> Int? {
        guard let amID = playlist.appleMusicPlaylistID else { return nil }
        if let count = trackCounts[amID] { return count }
        return playlist.isEditable ? 0 : nil
    }

    private func playlistRow(_ playlist: Playlist) -> some View {
        let isSelected: Bool = {
            guard case .playlist(let id, _, _) = selectedScope else { return false }
            return id == playlist.appleMusicPlaylistID
        }()
        return Button {
            guard let amID = playlist.appleMusicPlaylistID else { return }
            onPick(.playlist(id: amID, name: playlist.name, isEditable: playlist.isEditable))
            dismiss()
        } label: {
            HStack(spacing: 12) {
                PlaylistCoverView(appleMusicPlaylistID: playlist.appleMusicPlaylistID)

                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.name)
                        .foregroundStyle(.primary)
                    if !playlist.isEditable {
                        Text("Read-only")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if let count = displayCount(for: playlist) {
                    Text(count, format: .number)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .font(.body.weight(.semibold))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func artistRow(_ artist: Artist) -> some View {
        let isSelected: Bool = {
            guard case .artist(let id, _) = selectedScope else { return false }
            return id == artist.id.rawValue
        }()
        return Button {
            onPick(.artist(id: artist.id.rawValue, name: artist.name))
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Group {
                    if let artwork = artist.artwork {
                        ArtworkImage(artwork, width: 44, height: 44)
                    } else {
                        Rectangle()
                            .fill(.quaternary)
                            .overlay(
                                Image(systemName: "person.fill")
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                            )
                            .frame(width: 44, height: 44)
                    }
                }
                .clipShape(Circle())

                Text(artist.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .font(.body.weight(.semibold))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
