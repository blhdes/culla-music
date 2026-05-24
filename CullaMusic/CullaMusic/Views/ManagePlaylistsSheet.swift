import SwiftUI
import MusicKit

/// Lets the user pick which playlists appear in the swipe sidebar (capped to
/// `MusicSwipeViewModel.maxSidebar`) and create new ones. The rows are the
/// screen — a single glass slab on the calm mesh, with the live count baked
/// into a subtitle line so no section-card header competes with the list. The
/// New Playlist action lives in the toolbar as a quiet `+` because it's a
/// utility, not the page's primary purpose.
struct ManagePlaylistsSheet: View {
    @Bindable var viewModel: MusicSwipeViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccent) private var appAccent
    @State private var showCreate = false

    /// The up-swipe loved target. Hidden from the sidebar list below since the
    /// up-swipe already covers that playlist and double-listing it implies a
    /// toggle that wouldn't add anything. Configured in Settings.
    @AppStorage("lovedPlaylistID") private var lovedPlaylistID: String = ""

    private var maxSidebar: Int { MusicSwipeViewModel.maxSidebar }

    private var editablePlaylists: [Playlist] {
        viewModel.playlists.filter { playlist in
            guard playlist.isEditable else { return false }
            if !lovedPlaylistID.isEmpty,
               playlist.appleMusicPlaylistID == lovedPlaylistID {
                return false
            }
            return true
        }
    }

    private var isAtCapacity: Bool {
        !viewModel.canAddToSidebar && !editablePlaylists.isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LivingMeshBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        subtitle
                        listSlab
                        if isAtCapacity {
                            capacityCaption
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .padding(.bottom, 24)
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Manage Playlists")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showCreate = true
                    } label: {
                        Image(systemName: "plus")
                            .fontWeight(.semibold)
                    }
                    .accessibilityLabel("New playlist")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showCreate) {
                NewPlaylistSheet { name in
                    Task {
                        await viewModel.createPlaylist(
                            name: name,
                            addToSidebar: viewModel.canAddToSidebar
                        )
                    }
                }
            }
        }
    }

    // MARK: - Page-level caption

    /// Quiet count line above the slab. The digits tick via
    /// `.contentTransition(.numericText)` so toggling a row reads as a single
    /// motion (row bounce + count tick) without needing a floating chip.
    private var subtitle: some View {
        Text("\(viewModel.sidebarCount) of \(maxSidebar) in your sidebar")
            .font(.system(.footnote, design: .rounded))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .contentTransition(.numericText(countsDown: false))
            .animation(.snappy, value: viewModel.sidebarCount)
            .padding(.horizontal, 4)
    }

    // MARK: - Single glass slab list

    @ViewBuilder
    private var listSlab: some View {
        if editablePlaylists.isEmpty {
            emptyState
        } else {
            VStack(spacing: 4) {
                ForEach(Array(editablePlaylists.enumerated()), id: \.element.id) { index, playlist in
                    row(for: playlist)
                    if index < editablePlaylists.count - 1 {
                        Divider().opacity(0.4)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .glassSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.white.opacity(0.06), lineWidth: 1)
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note.list")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("No playlists yet")
                .font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundStyle(.primary)
            Text("Tap + to create your first one.")
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 18)
        .glassSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.06), lineWidth: 1)
        )
    }

    /// Soft "you've maxed the sidebar" line below the slab. Replaces silent
    /// `.opacity` dimming with a sentence so the user understands *why*
    /// unselected rows are inert.
    private var capacityCaption: some View {
        Text("Sidebar full — turn one off to add another.")
            .font(.system(.footnote, design: .rounded))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.top, 2)
    }

    @ViewBuilder
    private func row(for playlist: Playlist) -> some View {
        let isOn = playlist.isInSidebar
        let canEnable = viewModel.canAddToSidebar
        let isTappable = isOn || canEnable

        Button {
            if isOn {
                viewModel.setSidebar(playlist, included: false)
            } else if canEnable {
                viewModel.setSidebar(playlist, included: true)
            }
        } label: {
            HStack(spacing: 12) {
                PlaylistCoverView(
                    appleMusicPlaylistID: playlist.appleMusicPlaylistID,
                    size: 40,
                    cornerRadius: 8
                )

                Text(playlist.name)
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()

                // Only editable rows reach this sheet, so a nil from the
                // index means "truly empty playlist" — render "0" rather
                // than dropping the badge.
                let count = viewModel.membershipIndex.trackCount(
                    forPlaylistAMID: playlist.appleMusicPlaylistID
                ) ?? 0
                Text(count, format: .number)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                // Multi-select toggle idiom: always-rendered `circle` ↔
                // `checkmark.circle.fill` swap. Empty circle telegraphs
                // "this can be toggled," the swap-with-bounce makes
                // toggling feel landed.
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? appAccent : Color.secondary.opacity(0.4))
                    .font(.title3)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: isOn)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 6)
            .opacity(isTappable ? 1.0 : 0.4)
            .animation(.snappy(duration: 0.22), value: isOn)
        }
        .buttonStyle(.plain)
        .disabled(!isTappable)
    }
}

// MARK: - Playlist cover thumbnail

struct PlaylistCoverView: View {
    let appleMusicPlaylistID: String?
    var size: CGFloat = 44
    var cornerRadius: CGFloat = 8

    private var artwork: Artwork? {
        guard let id = appleMusicPlaylistID else { return nil }
        return MusicLibraryService.shared.artwork(forPlaylistID: id)
    }

    var body: some View {
        Group {
            if let artwork {
                ArtworkImage(artwork, width: size, height: size)
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    private var placeholder: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay(
                Image(systemName: "music.note.list")
                    .font(size > 44 ? .body : .caption)
                    .foregroundStyle(.secondary)
            )
    }
}
