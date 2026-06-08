import SwiftUI
import MusicKit
import UIKit

/// Liner / sleeve-notes sheet for an album, opened from the info button next to
/// the inline album label on the swipe card.
///
/// Resolves `song`'s album to a catalog `Album` first (so library-only or
/// uploaded tracks still get the *full* pressing's tracklist), then renders it
/// like the back of a vinyl sleeve — monospaced rows, durations right-aligned,
/// small-print label / © — in iOS 26 Liquid Glass. Each row taps to a 30s
/// preview, matching the Artist hub's Top Songs.
struct AlbumDetailSheet: View {
    let song: Song

    @Environment(\.dismiss) private var dismiss
    @State private var album: Album?
    @State private var resolutionState: ResolutionState = .loading

    private enum ResolutionState { case loading, resolved, failed }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(song.albumTitle ?? "Album")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .task(id: song.id.rawValue) { await resolve() }
    }

    @ViewBuilder
    private var content: some View {
        switch resolutionState {
        case .loading:
            AlbumLoadingView(title: song.albumTitle ?? "")
        case .resolved:
            if let album {
                AlbumLinerNotesView(album: album, currentTitle: song.title)
            }
        case .failed:
            AlbumUnavailableView(title: song.albumTitle ?? "")
        }
    }

    private func resolve() async {
        resolutionState = .loading
        album = nil
        do {
            if let resolved = try await MusicLibraryService.shared.resolveAlbum(for: song) {
                album = resolved
                resolutionState = .resolved
            } else {
                resolutionState = .failed
            }
        } catch {
            print("AlbumDetailSheet.resolve failed: \(error)")
            resolutionState = .failed
        }
    }
}

// MARK: - Liner notes (resolved album)

/// Renders the resolved album as a sleeve: cover hero, small-print metadata,
/// then the monospaced tracklist. Loads `.tracks` once, then crossfades the
/// assembled sheet in one beat (same pattern as the Artist detail view) so the
/// list doesn't pop in row-by-row.
private struct AlbumLinerNotesView: View {
    let album: Album
    /// Title of the song the sheet was opened from — that row gets a subtle
    /// accent so the page reads as "you are here on this record". Matched by
    /// title because the swipe song's ID (often a *library* ID) lives in a
    /// different namespace than the catalog album's track IDs.
    let currentTitle: String

    @State private var tracks: [MusicKit.Track] = []
    @State private var isReady = false

    /// Apple Music editorial blurb — loaded separately from the tracks so it can
    /// fade in once it lands (like the Artist sheet's Wikipedia "About"). Nil
    /// until resolved, and stays nil when the album has no note (section hidden).
    @State private var editorialText: String?
    /// First tap expands the clamped note to its full length (one-way). Unlike
    /// the artist bio there's no external article, so a fully-shown note has no
    /// further action.
    @State private var notesExpanded = false
    @State private var notesIsTruncated = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var notesCanExpand: Bool { notesIsTruncated && !notesExpanded }

    var body: some View {
        Group {
            if isReady {
                content.transition(.opacity)
            } else {
                AlbumLoadingView(title: album.title).transition(.opacity)
            }
        }
        .task(id: album.id.rawValue) { await loadTracks() }
        .task(id: album.id.rawValue) { await loadEditorial() }
    }

    private var content: some View {
        ScrollView {
            // Horizontal padding is applied per-section (matching
            // `ArtistDetailSheet`) instead of on this outer VStack, so the
            // tracklist rows can run full-width with edge-aligned hairline
            // dividers rather than sitting inside an inset floating card.
            VStack(spacing: 28) {
                hero
                    .padding(.horizontal, 20)
                editorialSection
                tracklist
            }
            .padding(.vertical, 24)
        }
        // The cover diffuses softly under the nav title as it scrolls — the
        // iOS 26 Liquid Glass scroll feel. No-op below iOS 26.
        .softScrollEdge()
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: 14) {
            Group {
                if let artwork = album.artwork {
                    ArtworkImage(artwork, width: 200, height: 200)
                } else {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(.thinMaterial)
                        .overlay(
                            Image(systemName: "opticaldisc")
                                .font(.system(size: 48, weight: .light))
                                .foregroundStyle(.secondary)
                        )
                }
            }
            .frame(width: 200, height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )
            // Neutral depth shadow — no accent bloom; the cover carries its own
            // colour (matches the Artist hero's restraint).
            .shadow(color: .black.opacity(album.artwork == nil ? 0.18 : 0.28), radius: 22, y: 12)

            VStack(spacing: 6) {
                Text(album.title)
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .multilineTextAlignment(.center)
                Text(album.artistName)
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                sleeveSmallPrint
                    .padding(.top, 2)
            }
        }
    }

    // MARK: Sleeve small-print

    /// One tight cluster of sleeve facts sitting directly under the title, so the
    /// album's identity (year · songs · runtime, then ©) reads as a single unit
    /// instead of floating in a separate block a section-gap away.
    private var sleeveSmallPrint: some View {
        VStack(spacing: 4) {
            Text(sleeveLine(count: trackCountForDisplay))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            // Apple's copyright string usually carries the label too
            // (e.g. "℗ 2017 Columbia Records"), so it stands in for the sleeve's
            // small-print line — MusicKit's `Album` exposes no separate label.
            if let copyright = trimmed(album.copyright) {
                Text(copyright)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Editorial notes

    /// The album's Apple Music blurb, styled like the Artist sheet's Wikipedia
    /// "About": clamped to a few lines with a "More" affordance that expands it
    /// in place. Hidden entirely when the album carries no note.
    @ViewBuilder
    private var editorialSection: some View {
        if let text = editorialText {
            VStack(spacing: 12) {
                sectionHeader("Notes")
                Button {
                    if notesCanExpand {
                        withAnimation(.easeInOut(duration: 0.25)) { notesExpanded = true }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(text)
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .lineLimit(notesExpanded ? nil : 5)
                            .truncationMode(.tail)
                            .multilineTextAlignment(.leading)
                            .background {
                                // Hidden full-length copy behind the clamp: when
                                // it doesn't fit, the clear fallback flags the
                                // note as truncated so we show "More".
                                if !notesExpanded {
                                    ViewThatFits(in: .vertical) {
                                        Text(text).font(.callout).hidden()
                                        Color.clear.onAppear { notesIsTruncated = true }
                                    }
                                }
                            }
                        if notesCanExpand {
                            HStack(spacing: 6) {
                                Image(systemName: "chevron.down")
                                Text("More")
                            }
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Block the tap once fully expanded without greying the text:
                // `.disabled` would dim the whole label, `allowsHitTesting`
                // keeps the note in crisp `.primary` whether compact or open.
                .allowsHitTesting(notesCanExpand)
            }
            .padding(.horizontal, 20)
            .transition(.opacity)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(.headline, design: .rounded).weight(.bold))
            Spacer()
        }
    }

    // MARK: Tracklist

    @ViewBuilder
    private var tracklist: some View {
        if tracks.isEmpty {
            VStack(spacing: 12) {
                sectionHeader("Tracklist")
                Text("Tracklist unavailable.")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 20)
        } else {
            VStack(spacing: 12) {
                sectionHeader("Tracklist")
                    .padding(.horizontal, 20)
                // Rows sit flush on the sleeve — no floating glass card — with
                // dividers inset to the title so the page matches the Artist
                // sheet's Top Songs instead of reading as a separate tile.
                VStack(spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { pair in
                        let track = pair.element
                        TrackLinerRow(
                            track: track,
                            position: track.trackNumber ?? (pair.offset + 1),
                            isCurrent: isCurrent(track)
                        )
                        if pair.offset < tracks.count - 1 {
                            Divider().padding(.leading, 58)
                        }
                    }
                }
            }
        }
    }

    // MARK: Derived values

    private var releaseYear: String? {
        guard let date = album.releaseDate else { return nil }
        return String(Calendar.current.component(.year, from: date))
    }

    private var totalRuntime: TimeInterval {
        tracks.reduce(0) { $0 + ($1.duration ?? 0) }
    }

    /// The real track count once tracks load; the album's advertised count
    /// meanwhile, so the sleeve line shows a number from the first frame.
    private var trackCountForDisplay: Int {
        tracks.isEmpty ? album.trackCount : tracks.count
    }

    /// One sleeve line of small-print — release year (when known), song count,
    /// and total runtime — joined by middots, e.g. "2017  ·  12 songs  ·  48:21".
    private func sleeveLine(count: Int) -> String {
        var parts: [String] = []
        if let releaseYear { parts.append(releaseYear) }
        parts.append("\(count) \(count == 1 ? "song" : "songs")")
        if totalRuntime > 0 { parts.append(formatRuntime(totalRuntime)) }
        return parts.joined(separator: "  ·  ")
    }

    private func formatRuntime(_ t: TimeInterval) -> String {
        let total = Int(t.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private func isCurrent(_ track: MusicKit.Track) -> Bool {
        let a = track.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let b = currentTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !a.isEmpty && a == b
    }

    private func loadTracks() async {
        if !tracks.isEmpty {
            isReady = true
            return
        }
        do {
            tracks = try await MusicLibraryService.shared.loadAlbumTracks(album)
        } catch {
            print("AlbumLinerNotesView.loadTracks failed: \(error)")
        }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.4)) {
            isReady = true
        }
    }

    private func loadEditorial() async {
        let text = await MusicLibraryService.shared.loadAlbumEditorial(for: album)
        guard let text else { return }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) {
            editorialText = text
        }
    }
}

// MARK: - Track row

/// One monospaced sleeve line: track number, title, an optional playing
/// indicator, and the duration right-aligned. Tapping toggles a 30s preview
/// (only for `.song` tracks — music videos aren't previewable here).
private struct TrackLinerRow: View {
    let track: MusicKit.Track
    let position: Int
    let isCurrent: Bool

    @Environment(\.appAccent) private var appAccent

    private var song: Song? {
        if case .song(let song) = track { return song }
        return nil
    }

    private var isPlaying: Bool {
        guard let song else { return false }
        let service = MusicLibraryService.shared
        return service.isPlayingPreview && service.nowPlayingSongID == song.id.rawValue
    }

    var body: some View {
        Button {
            guard let song else { return }
            let service = MusicLibraryService.shared
            if isPlaying {
                service.stopPreview()
            } else {
                service.playPreview(for: song)
            }
        } label: {
            rowBody
        }
        .buttonStyle(.plain)
        .disabled(song == nil)
    }

    private var rowBody: some View {
        let accented = isCurrent || isPlaying
        return HStack(spacing: 14) {
            Text(String(format: "%02d", position))
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(accented ? appAccent : .secondary)
                .frame(width: 24, alignment: .leading)

            // Title takes ALL the space the fixed columns leave — no competing
            // Spacer — so its slot width is deterministic and overflow is exact.
            // Only the row that's actually previewing scrolls; the rest stay
            // calmly tail-truncated.
            MarqueeText(
                text: track.title,
                // Same monospaced subheadline as before, but handed over as a
                // UIFont so the marquee can measure the title's true width.
                uiFont: .monospacedSystemFont(
                    ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize,
                    weight: .regular
                ),
                color: accented ? appAccent : .primary,
                isActive: isPlaying
            )

            // Fixed-width slot so the duration column never shifts when the
            // pause glyph appears on the playing row.
            ZStack {
                if isPlaying {
                    Image(systemName: "pause.fill")
                        .font(.caption2)
                        .foregroundStyle(appAccent)
                }
            }
            .frame(width: 12)

            Text(durationText)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                // Never let the duration get squeezed — it stays pinned right.
                .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    private var durationText: String {
        guard let duration = track.duration, duration > 0 else { return "--:--" }
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Marquee title

/// A single line of text that scrolls horizontally to reveal its full length
/// while `isActive` and the title is too wide to fit; otherwise it tail-
/// truncates like a normal line. Used for the now-playing track row so a long
/// title can be read in full without the row growing or the name staying
/// clipped. Honours Reduce Motion (stays truncated, never scrolls).
private struct MarqueeText: View {
    let text: String
    /// The exact `UIFont` the row renders with — used both to draw the title and
    /// to measure its true width. Measuring straight from the font (instead of a
    /// hidden SwiftUI copy) is the whole point: a hidden view gets clamped to the
    /// column width and can never report an overflow, which is what silently
    /// stopped the scroll before.
    let uiFont: UIFont
    let color: Color
    let isActive: Bool

    /// Drift speed in points per second — slow enough to read comfortably.
    private let speed: CGFloat = 30
    /// Beat held at the start before sliding, so the opening stays readable.
    private let edgePause: TimeInterval = 1.2
    /// Longer hold on the tail so the end of the title lingers before resetting.
    private let tailPause: TimeInterval = 2.0
    /// Soft cross-fade that hides the instant snap back to the start.
    private let fadeDuration: TimeInterval = 0.25
    /// A title that spills past the slot by no more than this many characters
    /// reads as "basically fits": on the playing row we shrink it a hair to show
    /// the whole thing instead of scrolling a pointless inch to reveal 2–3 chars.
    private let maxAbsorbableTrailChars: CGFloat = 3
    /// Floor for that shrink. A tiny trail needs only ~0.85–0.92, so 0.8 just
    /// bounds pathological cases — the text scales no further than it must to fit.
    private let trailFitFloor: CGFloat = 0.8

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    /// Faded to 0 only across the snap-back so the reset reads as a dissolve.
    @State private var scrollOpacity: Double = 1

    private var font: Font { Font(uiFont) }

    /// The title's true rendered width — a pure text measurement, so nothing in
    /// the layout can clamp it down to the visible column.
    private var textWidth: CGFloat {
        (text as NSString).size(withAttributes: [.font: uiFont]).width
    }

    /// How far the title spills past the visible slot.
    private var overflow: CGFloat { max(0, textWidth - containerWidth) }

    /// Width of one character in the row's font. It's monospaced here, so this is
    /// exact for every glyph — lets us size the "tiny trail" cutoff in characters
    /// rather than guessing at raw points.
    private var characterWidth: CGFloat {
        ("0" as NSString).size(withAttributes: [.font: uiFont]).width
    }

    /// True when the title overflows by only a few characters — small enough to
    /// reveal in full by shrinking a hair instead of scrolling.
    private var trailIsTiny: Bool {
        overflow > 1 && overflow <= maxAbsorbableTrailChars * characterWidth
    }

    /// On the playing row, a tiny trail shrinks to fit (full text, no ellipsis,
    /// no scroll) instead of sliding an inch to reveal 2–3 characters. Static, so
    /// it's fine under Reduce Motion too.
    private var shouldShrinkToFit: Bool {
        isActive && containerWidth > 1 && trailIsTiny
    }

    /// Scroll only a playing, overflowing row that isn't in Reduce Motion, has
    /// been measured, and overflows by *more* than a tiny trail (those shrink to
    /// fit instead of scrolling).
    private var shouldScroll: Bool {
        isActive && !reduceMotion && containerWidth > 1 && overflow > 1 && !trailIsTiny
    }

    var body: some View {
        // A plain truncating copy defines the slot and its width — it never grows
        // the column, so the measured overflow stays put. When scrolling, that
        // copy goes invisible (but keeps its size) and a full-width copy floats
        // on top in an overlay; overlays can't resize their parent, so the slide
        // can't inflate the slot out from under itself.
        line
            .truncationMode(.tail)
            // A tiny trail on the playing row scales down just enough to show the
            // whole title; every other state stays full-size (truncating or
            // scrolling exactly as before).
            .minimumScaleFactor(shouldShrinkToFit ? trailFitFloor : 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(shouldScroll ? 0 : 1)
            .background { containerMeasurer }
            .overlay(alignment: .leading) {
                if shouldScroll {
                    line
                        .fixedSize(horizontal: true, vertical: false)
                        .offset(x: offset)
                        .opacity(scrollOpacity)
                }
            }
            .clipped()
            // One declarative driver: restart the slide whenever the playing
            // state or the measured overflow changes, settle back to 0 otherwise.
            .task(id: scrollKey) { await runScroll() }
    }

    private var line: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
    }

    /// Measures the visible slot so we know when the title overflows it.
    private var containerMeasurer: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { containerWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, w in containerWidth = w }
        }
    }

    // MARK: Animation

    /// Flips whenever the slide should reconfigure: encodes both *whether* we
    /// scroll and *how far*, so a re-measure restarts the loop cleanly while an
    /// idle row keeps a stable `-1`.
    private var scrollKey: Int {
        shouldScroll ? Int(overflow.rounded()) : -1
    }

    /// Loop the offset one way: hold at the start, slide to the far end, hold so
    /// the tail can be read, then fade out, snap back to 0 while invisible, fade
    /// in, and repeat. Driven by `.task(id:)`, so it auto-cancels on re-measure
    /// or disappear.
    private func runScroll() async {
        guard shouldScroll, overflow > 1 else {
            offset = 0
            scrollOpacity = 1
            return
        }
        offset = 0
        scrollOpacity = 1
        do {
            try await Task.sleep(for: .seconds(edgePause))
            while !Task.isCancelled {
                let distance = overflow
                guard distance > 1 else { break }
                let duration = TimeInterval(distance / speed)
                // Slide to the end and linger on the tail.
                withAnimation(.linear(duration: duration)) { offset = -distance }
                try await Task.sleep(for: .seconds(duration + tailPause))
                // Fade out, snap back to the start unseen, fade in, then hold.
                withAnimation(.easeInOut(duration: fadeDuration)) { scrollOpacity = 0 }
                try await Task.sleep(for: .seconds(fadeDuration))
                offset = 0
                withAnimation(.easeInOut(duration: fadeDuration)) { scrollOpacity = 1 }
                try await Task.sleep(for: .seconds(fadeDuration + edgePause))
            }
        } catch {
            // Cancelled (re-measure / view gone) — the next task or the guard
            // above settles the offset; nothing to do here.
        }
    }
}

// MARK: - Loading / unavailable states

/// Content-shaped skeleton mirroring `AlbumLinerNotesView`'s geometry: a cover
/// bone, the already-known title rendered solid, and shimmering track rows in a
/// glass card. Top-aligned so the cover lands exactly where the real hero will
/// — a centered spinner would slide it up on reveal. Shared across the outer
/// resolve and inner track-fetch phases so the placeholder stays continuous.
private struct AlbumLoadingView: View {
    let title: String

    /// Varied widths so the title bones don't read as a rigid grid.
    private let titleWidths: [CGFloat] = [180, 132, 156, 120, 168, 110]

    var body: some View {
        // Same per-section inset + rhythm as the resolved sheet, so the cover
        // and rows materialize exactly where they'll live.
        VStack(spacing: 28) {
            heroPlaceholder
                .padding(.horizontal, 20)
            tracklistSkeleton
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var heroPlaceholder: some View {
        VStack(spacing: 14) {
            SkeletonShape(shape: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .frame(width: 200, height: 200)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                )

            VStack(spacing: 6) {
                // The title is known up front, so it renders as finished content
                // — only the unresolved artist / sleeve line get bones.
                if !title.isEmpty {
                    Text(title)
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .multilineTextAlignment(.center)
                }
                SkeletonShape(shape: Capsule())
                    .frame(width: 150, height: 11)
                SkeletonShape(shape: Capsule())
                    .frame(width: 110, height: 9)
                    .padding(.top, 2)
            }
        }
    }

    private var tracklistSkeleton: some View {
        VStack(spacing: 12) {
            // Stands in for the "Tracklist" section header.
            HStack {
                SkeletonShape(shape: Capsule())
                    .frame(width: 96, height: 15)
                Spacer()
            }
            .padding(.horizontal, 20)

            VStack(spacing: 0) {
                ForEach(0..<6, id: \.self) { index in
                    row(index: index)
                    if index < 5 {
                        Divider().padding(.leading, 58)
                    }
                }
            }
        }
    }

    /// Mirrors `TrackLinerRow`: 24pt number slot, flexible title, trailing
    /// duration, 20pt side / 11pt vertical padding — so rows reveal in place.
    private func row(index: Int) -> some View {
        HStack(spacing: 14) {
            SkeletonShape(shape: Capsule())
                .frame(width: 16, height: 11)
                .frame(width: 24, alignment: .leading)
            SkeletonShape(shape: Capsule())
                .frame(width: titleWidths[index % titleWidths.count], height: 11)
            Spacer(minLength: 8)
            SkeletonShape(shape: Capsule())
                .frame(width: 30, height: 11)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
    }
}

private struct AlbumUnavailableView: View {
    let title: String

    var body: some View {
        VStack(spacing: 16) {
            HeroIconTile(systemName: "opticaldisc", size: 140, foreground: .secondary)
            Text(title.isEmpty ? "Album" : title)
                .font(.system(.title3, design: .rounded).weight(.bold))
                .multilineTextAlignment(.center)
            Text("No liner notes from Apple Music for this album.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
