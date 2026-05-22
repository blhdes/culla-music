import SwiftUI
import MusicKit

/// Lets the user pick which playlists appear in the swipe sidebar (capped to
/// `MusicSwipeViewModel.maxSidebar`) and create new ones. Redesigned around
/// the GlassPanel vocabulary shared with Settings and LovedPlaylistPickerSheet
/// — the New Playlist CTA is promoted to the top so it reads as the primary
/// action instead of a list row.
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

    var body: some View {
        NavigationStack {
            ZStack {
                LivingMeshBackground()

                ScrollView {
                    VStack(spacing: 18) {
                        GradientCapsuleButton(
                            title: "New playlist",
                            icon: "plus"
                        ) {
                            showCreate = true
                        }

                        GlassPanel(
                            icon: "sidebar.right",
                            title: "Sidebar",
                            trailing: { sidebarCountChip }
                        ) {
                            sidebarContent
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 20)
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Manage Playlists")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
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

    // MARK: - Sidebar card content

    /// Live capacity badge rendered into the GlassPanel's trailing slot.
    /// The numeric digits cross-fade via `.contentTransition(.numericText)` so
    /// toggling a row reads as a single motion (row bounce + chip tick).
    private var sidebarCountChip: some View {
        Text("\(viewModel.sidebarCount) / \(maxSidebar)")
            .font(.system(.caption, design: .rounded).weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.primary)
            .contentTransition(.numericText(countsDown: false))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .glassSurface(in: Capsule())
            .animation(.snappy, value: viewModel.sidebarCount)
    }

    @ViewBuilder
    private var sidebarContent: some View {
        if editablePlaylists.isEmpty {
            Text("No playlists yet — create one above.")
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
        } else {
            VStack(spacing: 4) {
                ForEach(Array(editablePlaylists.enumerated()), id: \.element.id) { index, playlist in
                    row(for: playlist)
                    if index < editablePlaylists.count - 1 {
                        Divider().opacity(0.4)
                    }
                }
            }
        }
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
            .padding(.vertical, 4)
            .opacity(isTappable ? 1.0 : 0.35)
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
