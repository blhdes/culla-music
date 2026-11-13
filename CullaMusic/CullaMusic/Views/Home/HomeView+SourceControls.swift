import SwiftUI

// Sort From card and the scope-time chips (order, include dismissed,
// copy/move). Split out of HomeView.swift; reads HomeView's state directly.
extension HomeView {
    /// True when the user has picked a Sort From source that we can't remove
    /// songs from (Apple-curated, smart Favorites, shared-by-others, etc.).
    /// Forces the transfer mode to `.copy` so we never attempt a doomed write.
    private var selectedSourceIsReadOnly: Bool {
        if case .playlist(_, _, let isEditable) = source { return !isEditable }
        return false
    }

    private var selectedSourceCanRemove: Bool {
        guard case .playlist(let id, _, _) = source else { return false }
        return playlistCanRemove(amID: id)
    }

    // MARK: - Source pill (promoted to full-width glass card)

    var sourceFilterButton: some View {
        Button {
            showSourcePicker = true
        } label: {
            HStack(spacing: 12) {
                if let source {
                    sourceThumbnail(for: source)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("SORT FROM")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .tracking(1.2)
                            .foregroundStyle(.secondary)
                        Text(source.displayName)
                            .font(.system(.footnote, design: .rounded).weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Button {
                        self.source = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                } else {
                    Image(systemName: "music.note.list")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                    Text("All library")
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .glassSurface(
                in: RoundedRectangle(cornerRadius: 14, style: .continuous),
                interactive: true
            )
            // Continuous glass identity for the source pill so its surface
            // morphs (not pops) as its content swaps between "All library" and a
            // picked source, and refracts with the chips below it.
            .glassMorphID("home.sourcePill", in: glassMorph)
            .glassMorphTransition(.matchedGeometry, reduceMotion: reduceMotion)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func sourceThumbnail(for source: SourceScope) -> some View {
        switch source {
        case .playlist(let id, _, _):
            PlaylistCoverView(
                appleMusicPlaylistID: id,
                size: 36,
                cornerRadius: 8
            )
        case .artist(let id, let name):
            ArtistThumbnail(artistID: id, artistName: name, size: 36)
        }
    }

    // MARK: - Order toggle

    /// Compact pill that flips between newest-first and oldest-first on tap.
    /// Replaces the old segmented control — order is a 2-state choice, the
    /// segmented control was overkill and ate a full row of vertical space.
    var orderRow: some View {
        HStack(spacing: 8) {
            Text("Order")
                .font(.system(.footnote, design: .rounded).weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                let current = SortOrder(rawValue: sortOrderRaw) ?? .newestFirst
                let next: SortOrder = current == .newestFirst ? .oldestFirst : .newestFirst
                withAnimation(.snappy(duration: 0.22)) {
                    sortOrderRaw = next.rawValue
                }
            } label: {
                let current = SortOrder(rawValue: sortOrderRaw) ?? .newestFirst
                HStack(spacing: 6) {
                    Image(systemName: current == .newestFirst ? "arrow.down" : "arrow.up")
                        .font(.caption.weight(.bold))
                        .contentTransition(.symbolEffect(.replace))
                    Text(current.label)
                        .font(.system(.footnote, design: .rounded).weight(.semibold))
                        .contentTransition(.opacity)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .contentShape(Capsule())
                .glassSurface(in: Capsule(), interactive: true)
                // Always-present chip — a stable glass identity so it refracts
                // with the source pill/dismissed chip in the shared container.
                .glassMorphID("home.order", in: glassMorph)
                .glassMorphTransition(.matchedGeometry, reduceMotion: reduceMotion)
            }
            .buttonStyle(.plain)
        }
    }

    /// Opt-in toggle for scoped sessions to also surface dismissed tracks.
    /// Mirrors `orderRow`'s chip style so the two scope-time controls feel
    /// like one family.
    var includeDismissedRow: some View {
        HStack(spacing: 8) {
            Text("Include dismissed")
                .font(.system(.footnote, design: .rounded).weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                withAnimation(.snappy(duration: 0.22)) {
                    includeDismissedInScope.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: includeDismissedInScope ? "checkmark" : "xmark")
                        .font(.caption.weight(.bold))
                        .contentTransition(.symbolEffect(.replace))
                    Text(includeDismissedInScope ? "On" : "Off")
                        .font(.system(.footnote, design: .rounded).weight(.semibold))
                        .contentTransition(.opacity)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .contentShape(Capsule())
                .glassSurface(in: Capsule(), interactive: true)
                // This chip only exists in scoped sessions, so it materializes
                // as glass when a source is picked rather than scaling in cold.
                .glassMorphID("home.includeDismissed", in: glassMorph)
                .glassMorphTransition(.materialize, reduceMotion: reduceMotion)
            }
            .buttonStyle(.plain)
        }
    }

    /// Two-state Keep/Move chip, mirroring `orderRow` and `includeDismissedRow`
    /// so all three scope-time controls share one vocabulary. Replaces the old
    /// segmented control — the only stock control left on the screen, and a
    /// full-width band for what is a 2-state flip. Move out removes from the
    /// source, which Apple only allows on playlists Culla created, so the chip
    /// is locked to Keep (dimmed, non-tappable) everywhere else; the footer
    /// line explains why.
    var sourceTransferPicker: some View {
        let isReadOnly = selectedSourceIsReadOnly
        let canRemove = selectedSourceCanRemove
        let storedMode = SourceTransferMode(rawValue: sourceTransferModeRaw) ?? .copy
        let displayMode: SourceTransferMode = canRemove ? storedMode : .copy

        return VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text("Source songs")
                    .font(.system(.footnote, design: .rounded).weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    let next: SourceTransferMode = displayMode == .copy ? .move : .copy
                    withAnimation(.snappy(duration: 0.22)) {
                        sourceTransferModeRaw = next.rawValue
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: displayMode == .copy ? "square.on.square" : "arrow.up.right.square")
                            .font(.caption.weight(.bold))
                            .contentTransition(.symbolEffect(.replace))
                        Text(displayMode.label)
                            .font(.system(.footnote, design: .rounded).weight(.semibold))
                            .contentTransition(.opacity)
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .contentShape(Capsule())
                    .glassSurface(in: Capsule(), interactive: true)
                    // Like the include-dismissed chip, this only exists once a
                    // playlist source is picked — materialize it as glass.
                    .glassMorphID("home.transferMode", in: glassMorph)
                    .glassMorphTransition(.materialize, reduceMotion: reduceMotion)
                }
                .buttonStyle(.plain)
                .disabled(!canRemove)
                .opacity(canRemove ? 1.0 : 0.45)
            }

            Text(transferModeFooter(isReadOnly: isReadOnly, canRemove: canRemove, mode: displayMode))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 20)
    }

    private func transferModeFooter(isReadOnly: Bool, canRemove: Bool, mode: SourceTransferMode) -> String {
        if isReadOnly {
            return String(localized: "This playlist is read-only — sorted songs stay where they are.")
        }
        if !canRemove {
            return String(localized: "Songs can only be moved out of playlists Culla created — they'll stay here.")
        }
        return mode == .copy
            ? String(localized: "Sorted songs stay in the source playlist too.")
            : String(localized: "Sorted songs are removed from the source playlist.")
    }
}
