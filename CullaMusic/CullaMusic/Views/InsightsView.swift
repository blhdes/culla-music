import SwiftUI
import SwiftData
import Charts
import MusicKit

/// Full-screen stats view opened from Settings — the music sibling of the
/// photo app's Insights. Everything except Top Artists is computed live from
/// the durable SwiftData rows (`SortedSong` / `DismissedSong`), so the screen
/// works retroactively over the user's whole sorting history with no counters.
struct InsightsView: View {
    @Query private var sortedSongs: [SortedSong]
    @Query private var dismissedSongs: [DismissedSong]
    @Query(sort: \Playlist.displayOrder) private var playlists: [Playlist]

    @AppStorage("lovedPlaylistID") private var lovedPlaylistID: String = ""
    @AppStorage("appColorScheme") private var colorSchemeRaw: String = "system"

    @State private var model = InsightsModel()
    /// Seed for the artist hub opened from a Top Artists row.
    @State private var artistSheetSong: Song?
    /// Whether "Where they went" shows every playlist or just the top 5.
    @State private var showAllPlaylists = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccent) private var appAccent

    // Same presentation-host pinning as SettingsView.resolvedColorScheme —
    // the artist sheet opens from inside this full-screen cover, so it needs
    // its own pin to follow a theme override.
    private var resolvedColorScheme: ColorScheme? {
        switch colorSchemeRaw {
        case "light": .light
        case "dark":  .dark
        default:      nil
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if sortedSongs.isEmpty && dismissedSongs.isEmpty {
                    emptyState
                } else {
                    statsContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground).ignoresSafeArea())
            .navigationTitle("Insights")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .task {
                model.calculateStreaks(from: sortedSongs.map(\.sortedAt))
                await model.loadTasteProfile(recentFirstSongIDs: recentFirstSortedIDs)
            }
            .onChange(of: sortedSongs.count) {
                model.calculateStreaks(from: sortedSongs.map(\.sortedAt))
            }
            .sheet(item: $artistSheetSong) { song in
                ArtistDetailSheet(song: song)
                    .sheetColorScheme(resolvedColorScheme)
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 24) {
            HeroIconTile(systemName: "chart.line.uptrend.xyaxis", pulse: true)
            Text("Start sorting to see\nyour journey here")
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Content

    private var statsContent: some View {
        // One evaluation per body pass — both are O(history) walks that fault
        // SwiftData relationships, and each value feeds a gate *and* a card.
        let slices = playlistSlices
        let loved = lovedCount

        return ScrollView {
            GlassStack(spacing: 22) {
                // Hero — the count ticks via numericText when it changes.
                VStack(spacing: 4) {
                    Text("\(sortedSongs.count)")
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.snappy, value: sortedSongs.count)
                    Text("songs sorted")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.secondary)
                    if let coverage = libraryCoverage {
                        coverageBar(coverage)
                            .padding(.top, 12)
                    }
                }
                .padding(.top, 16)

                HStack(spacing: 14) {
                    streakBadge(icon: "flame.fill", value: model.currentStreak, label: "Current")
                    streakBadge(icon: "trophy.fill", value: model.longestStreak, label: "Best")
                }

                if !slices.isEmpty {
                    playlistBreakdown(slices)
                }

                activityChart

                topArtistsCard

                // Taste and Eras share the artists' resolve — bones while it
                // runs, so finishing doesn't shove the cards below around.
                if model.isResolvingArtists {
                    skeletonPanel(icon: "guitars.fill", title: "Taste")
                    skeletonPanel(icon: "hourglass", title: "Eras")
                } else {
                    if !model.genres.isEmpty {
                        tasteCard
                    }
                    if !model.decades.isEmpty {
                        eraCard
                    }
                }

                detailsCard(lovedCount: loved)

                if loved > 0 {
                    lovedHighlight(count: loved)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 40)
        }
        .scrollContentBackground(.hidden)
        .softScrollEdge()
    }

    // MARK: - Playlist breakdown

    private struct PlaylistSlice: Identifiable {
        let id: UUID
        let name: String
        let count: Int
        let isLoved: Bool
    }

    /// Sorts per playlist, largest first. Counts every sort ever made (the
    /// screen measures activity, not current playlist contents), so voided
    /// rows still count — the song was sorted, even if it later left.
    private var playlistSlices: [PlaylistSlice] {
        playlists
            .filter { !$0.sortedSongs.isEmpty }
            .map { playlist in
                PlaylistSlice(
                    id: playlist.id,
                    name: playlist.name,
                    count: playlist.sortedSongs.count,
                    isLoved: isLovedPlaylist(playlist)
                )
            }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.name < rhs.name
            }
    }

    private func playlistBreakdown(_ slices: [PlaylistSlice]) -> some View {
        let top = showAllPlaylists ? slices : Array(slices.prefix(5))
        // Always the biggest slice overall — bar lengths keep their meaning
        // whether the card is collapsed or expanded.
        let maxCount = slices.first?.count ?? 1
        let remaining = slices.count - top.count

        return GlassPanel(icon: "square.stack.3d.up.fill", title: "Where they went") {
            VStack(spacing: 14) {
                ForEach(Array(top.enumerated()), id: \.element.id) { rank, slice in
                    playlistBar(slice, maxCount: maxCount, rank: rank)
                }
                if slices.count > 5 {
                    Button {
                        withAnimation(.snappy) { showAllPlaylists.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            if showAllPlaylists {
                                Text("Show less")
                            } else {
                                Text("+ \(remaining) more")
                            }
                            Image(systemName: "chevron.down")
                                .font(.caption2.weight(.semibold))
                                .rotationEffect(.degrees(showAllPlaylists ? 180 : 0))
                        }
                        .font(.system(.caption, design: .rounded).weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func playlistBar(_ slice: PlaylistSlice, maxCount: Int, rank: Int) -> some View {
        statBar(
            label: HStack(spacing: 6) {
                if slice.isLoved {
                    Image(systemName: "heart.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(appAccent)
                }
                Text(slice.name)
                    .font(.system(.footnote, design: .rounded).weight(.medium))
                    .lineLimit(1)
            },
            value: "\(slice.count)",
            fraction: maxCount > 0 ? CGFloat(slice.count) / CGFloat(maxCount) : 0,
            rank: rank
        )
    }

    /// Shared bar row for the breakdown cards (playlists, genres): label +
    /// trailing value over a capsule bar. Length encodes `fraction`; bars fade
    /// with `rank` — the top row reads strongest, depth rather than data.
    private func statBar(
        label: some View,
        value: String,
        fraction: CGFloat,
        rank: Int
    ) -> some View {
        let barOpacity = max(0.9 - Double(rank) * 0.15, 0.3)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                label
                Spacer(minLength: 8)
                Text(value)
                    .font(.system(.footnote, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(appAccent.opacity(barOpacity))
                        .frame(width: max(geo.size.width * fraction, 8))
                }
            }
            .frame(height: 8)
        }
    }

    // MARK: - Activity chart

    private struct ChartPoint: Identifiable {
        let id = UUID()
        let date: Date
        let count: Int
        let series: String
    }

    private var sortedSeriesLabel: String { String(localized: "Sorted") }
    private var dismissedSeriesLabel: String { String(localized: "Dismissed") }

    /// One point per day per series over the last 8 days (7 back + today),
    /// built straight from the durable rows — no separate daily-stats model
    /// needed, unlike the photo app.
    private var chartData: [ChartPoint] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let startDay = calendar.date(byAdding: .day, value: -7, to: today)!
        let days = (0..<8).map { calendar.date(byAdding: .day, value: $0, to: startDay)! }

        let sortedByDay = Dictionary(
            grouping: sortedSongs.filter { $0.sortedAt >= startDay },
            by: { calendar.startOfDay(for: $0.sortedAt) }
        ).mapValues { $0.count }

        let dismissedByDay = Dictionary(
            grouping: dismissedSongs.filter { $0.dismissedAt >= startDay },
            by: { calendar.startOfDay(for: $0.dismissedAt) }
        ).mapValues { $0.count }

        return days.flatMap { day in
            [
                ChartPoint(date: day, count: sortedByDay[day] ?? 0, series: sortedSeriesLabel),
                ChartPoint(date: day, count: dismissedByDay[day] ?? 0, series: dismissedSeriesLabel),
            ]
        }
    }

    private var activityChart: some View {
        // One evaluation — the marks and the y-domain share the same grouping.
        let data = chartData

        return GlassPanel(icon: "chart.xyaxis.line", title: "Last 7 days") {
            Chart(data) { point in
                LineMark(
                    x: .value("Day", point.date, unit: .day),
                    y: .value("Count", point.count)
                )
                .foregroundStyle(by: .value("Series", point.series))
                // Dismissed gets a dash + its own marker shape, so the two
                // lines never rely on color alone to be told apart.
                .lineStyle(
                    point.series == dismissedSeriesLabel
                        ? StrokeStyle(lineWidth: 2, dash: [5, 4])
                        : StrokeStyle(lineWidth: 2)
                )
                .symbol(by: .value("Series", point.series))
                .symbolSize(28)
            }
            .chartForegroundStyleScale([
                sortedSeriesLabel: appAccent,
                dismissedSeriesLabel: Color(.systemGray2),
            ])
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { value in
                    if let date = value.as(Date.self) {
                        AxisValueLabel {
                            Text(date, format: .dateTime.weekday(.abbreviated))
                                .font(.caption2)
                        }
                    }
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    AxisValueLabel()
                }
            }
            .chartYScale(domain: 0...max(data.map(\.count).max() ?? 1, 1))
            .chartLegend(position: .bottom, alignment: .center, spacing: 12)
            .frame(height: 180)
        }
    }

    // MARK: - Top artists

    @ViewBuilder
    private var topArtistsCard: some View {
        // Three states: bones while resolving, ranked rows on success, and
        // nothing at all if the resolve came back empty/failed — a stats
        // screen shouldn't surface a lookup error.
        if model.isResolvingArtists {
            skeletonPanel(icon: "music.mic", title: "Top artists")
        } else if !model.topArtists.isEmpty {
            GlassPanel(icon: "music.mic", title: "Top artists") {
                VStack(spacing: 0) {
                    ForEach(Array(model.topArtists.enumerated()), id: \.element.id) { rank, artist in
                        // Every stat is a door: a row with a seed song opens
                        // the same artist hub the swipe card's info button
                        // does. Rows without one (no library resolve) stay
                        // plain — no chevron, nothing to open.
                        Button {
                            artistSheetSong = artist.seedSong
                        } label: {
                            HStack(spacing: 12) {
                                Text("\(rank + 1)")
                                    .font(.system(.footnote, design: .rounded).weight(.bold))
                                    .foregroundStyle(rank == 0 ? appAccent : .secondary)
                                    .frame(width: 18)
                                Text(artist.name)
                                    .font(.system(.body, design: .rounded))
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                artistAvatar(artist)
                                Text("\(artist.count)")
                                    .font(.system(.body, design: .rounded).weight(.medium))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                if artist.seedSong != nil {
                                    Image(systemName: "chevron.right")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(artist.seedSong == nil)
                    }
                }
            }
        }
    }

    /// Loading bones for the cards fed by the async taste resolve.
    private func skeletonPanel(icon: String, title: LocalizedStringKey) -> some View {
        GlassPanel(icon: icon, title: title) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach([150, 120, 170] as [CGFloat], id: \.self) { width in
                    SkeletonShape(shape: Capsule())
                        .frame(width: width, height: 12)
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// Round artist-page portrait sitting just before the count, in three
    /// states: a shimmering bone while the portrait lookup is in flight, the
    /// portrait once it lands, and the initial-letter circle only when the
    /// lookup finished empty (no catalog page). The bone is layered *behind*
    /// `ArtworkImage` rather than swapped with it (`ArtworkImage` is
    /// transparent while it downloads — see the same pattern in
    /// ManagePlaylistsSheet), so the face paints over a still-loading shimmer
    /// instead of popping over a settled letter. Fixed frame either way keeps
    /// the count column aligned.
    private func artistAvatar(_ artist: InsightsModel.ArtistCount) -> some View {
        ZStack {
            if artist.portraitResolved && artist.artwork == nil {
                Circle()
                    .fill(Color.primary.opacity(0.08))
                Text(artist.name.prefix(1).uppercased())
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(.secondary)
            } else {
                SkeletonShape(shape: Circle())
            }
            if let artwork = artist.artwork {
                ArtworkImage(artwork, width: 28, height: 28)
                    .clipShape(Circle())
            }
        }
        .frame(width: 28, height: 28)
        // Bone → letter is a real state change (lookup came back empty);
        // crossfade it instead of snapping.
        .animation(.easeOut(duration: 0.25), value: artist.portraitResolved)
    }

    // MARK: - Recent taste

    /// Genre mix of the whole sorted history, in the same bar language as the
    /// playlist breakdown. The trailing number is the share of sorts carrying
    /// that genre — shares overlap by design (a song can be tagged with
    /// several genres), so they're per-row facts, not slices of 100%.
    private var tasteCard: some View {
        let maxCount = model.genres.first?.count ?? 1

        return GlassPanel(icon: "guitars.fill", title: "Taste") {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(model.genres.enumerated()), id: \.element.id) { rank, genre in
                    statBar(
                        label: Text(genre.name)
                            .font(.system(.footnote, design: .rounded).weight(.medium))
                            .lineLimit(1),
                        value: genreShareText(genre),
                        fraction: maxCount > 0 ? CGFloat(genre.count) / CGFloat(maxCount) : 0,
                        rank: rank
                    )
                }
                if model.musicSeconds > 0 {
                    Text("≈ \(formattedMusicTime) of music sorted")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
            }
        }
    }

    private func genreShareText(_ genre: InsightsModel.GenreShare) -> String {
        let share = Double(genre.count) / Double(max(model.resolvedEventCount, 1))
        return share.formatted(.percent.precision(.fractionLength(0)))
    }

    private var formattedMusicTime: String {
        Duration.seconds(model.musicSeconds).formatted(
            .units(allowed: [.hours, .minutes], width: .abbreviated, maximumUnitCount: 2)
        )
    }

    // MARK: - Eras

    /// Release-decade histogram of the sorted history — "when is your music
    /// from", the era companion to the genre mix. The model zero-fills the
    /// decades in between, so gaps show as gaps.
    private var eraCard: some View {
        let bins = model.decades
        // Short "'90s" tags collide when the sample spans a century (1920 and
        // 2020 are both "'20s"), and a duplicated category in the pinned
        // domain corrupts the chart — fall back to full "1920s" labels then.
        let short = bins.map { String(format: "'%02ds", $0.decade % 100) }
        let labels = Set(short).count == short.count
            ? short
            : bins.map { "\($0.decade)s" }

        return GlassPanel(icon: "hourglass", title: "Eras") {
            Chart {
                ForEach(bins.indices, id: \.self) { index in
                    BarMark(
                        x: .value("Decade", labels[index]),
                        y: .value("Sorts", bins[index].count)
                    )
                    .foregroundStyle(appAccent.opacity(0.85))
                    .cornerRadius(3)
                }
            }
            // String categories sort alphabetically by default, which would
            // put '00s before '90s — pin the axis to the model's time order.
            .chartXScale(domain: labels)
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    AxisValueLabel()
                }
            }
            .frame(height: 140)
        }
    }

    // MARK: - Details

    private func detailsCard(lovedCount: Int) -> some View {
        GlassPanel(icon: "list.bullet.rectangle.fill", title: "Details") {
            VStack(spacing: 0) {
                // Active rows only, matching Home's badge — voided rows (song
                // deleted from the library) are History tombstones. The other
                // stats keep ALL rows on purpose: they count decisions made,
                // and a decision doesn't un-happen when its song is deleted.
                detailRow("Dismissed", value: "\(dismissedSongs.count { $0.voidedAt == nil })")
                detailRow("Keep rate", value: keepRateText)
                detailRow("Loved", value: "\(lovedCount)")
                detailRow("Playlists", value: "\(playlists.count)")
                detailRow("Busiest day", value: busiestDayText)
                detailRow("Sorting since", value: sortingSinceText)
            }
        }
    }

    private func detailRow(_ label: LocalizedStringKey, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
                .monospacedDigit()
        }
        .font(.system(.body, design: .rounded))
        .padding(.vertical, 8)
    }

    // MARK: - Loved highlight

    private func lovedHighlight(count: Int) -> some View {
        GlassPanel(icon: "heart.fill", title: "Loved") {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(count)")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("songs loved")
                        .font(.system(.headline, design: .rounded).weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text("Every up-swipe, kept for good")
                    .font(.system(.footnote, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Library coverage

    /// Fraction of the library that's been through the deck. The "songs
    /// remaining" half comes from Home's day-scoped cached library walk
    /// (`HomeViewModel.CacheKey`) — Insights never walks the library itself,
    /// so this is nil (bar hidden) until Home has cached a count once. The
    /// cache can be up to a day stale, which is fine for a progress bar; and
    /// because the total is handled + remaining, the fraction stays below 1
    /// even when handled rows reference songs that have since left the library.
    private var libraryCoverage: Double? {
        guard UserDefaults.standard.object(forKey: HomeViewModel.CacheKey.libraryValue) != nil else {
            return nil
        }
        let remaining = UserDefaults.standard.integer(forKey: HomeViewModel.CacheKey.libraryValue)

        // Distinct songs, not sort events — a song sorted into two playlists
        // was still only one library decision.
        var handledIDs = Set(sortedSongs.map(\.songID))
        handledIDs.formUnion(dismissedSongs.map(\.songID))

        let total = handledIDs.count + remaining
        guard total > 0 else { return nil }
        return Double(handledIDs.count) / Double(total)
    }

    /// Slim centered gauge under the hero count — the "how far through the
    /// library" story. Fixed width so it reads as a gauge, not a divider.
    private func coverageBar(_ fraction: Double) -> some View {
        VStack(spacing: 6) {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(appAccent.opacity(0.85))
                    .frame(width: max(180 * fraction, 6))
            }
            .frame(width: 180, height: 6)
            Text("≈ \(fraction.formatted(.percent.precision(.fractionLength(0)))) of your library handled")
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Computed stats

    /// Kept vs. every decision made. Counts rows (not distinct songs) so it
    /// matches the hero and Dismissed numbers it sits between.
    private var keepRateText: String {
        let decisions = sortedSongs.count + dismissedSongs.count
        guard decisions > 0 else { return "—" }
        let rate = Double(sortedSongs.count) / Double(decisions)
        return rate.formatted(.percent.precision(.fractionLength(0)))
    }

    /// Sorted-song IDs newest-first, feeding the taste-profile resolve.
    private var recentFirstSortedIDs: [String] {
        sortedSongs
            .sorted { $0.sortedAt > $1.sortedAt }
            .map(\.songID)
    }

    /// Matches the stored loved-playlist pointer; before the first resolve
    /// ever runs (Auto mode, nothing loved yet) falls back to the well-known
    /// auto-created name so an adopted "Culla Loves" still counts.
    private func isLovedPlaylist(_ playlist: Playlist) -> Bool {
        if !lovedPlaylistID.isEmpty {
            return playlist.appleMusicPlaylistID == lovedPlaylistID
        }
        return playlist.name == LovedPlaylistResolver.defaultName
    }

    private var lovedCount: Int {
        sortedSongs.count { row in
            guard let playlist = row.playlist else { return false }
            return isLovedPlaylist(playlist)
        }
    }

    private var busiestDayText: String {
        let calendar = Calendar.current
        let byDay = Dictionary(
            grouping: sortedSongs,
            by: { calendar.startOfDay(for: $0.sortedAt) }
        ).mapValues { $0.count }

        guard let top = byDay.max(by: { $0.value < $1.value }) else { return "—" }
        let dayText = top.key.formatted(.dateTime.month(.abbreviated).day())
        return "\(top.value) · \(dayText)"
    }

    private var sortingSinceText: String {
        guard let first = sortedSongs.map(\.sortedAt).min() else { return "—" }
        return first.formatted(.dateTime.month(.wide).year())
    }

    // MARK: - Streak badge

    private func streakBadge(icon: String, value: Int, label: LocalizedStringKey) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(value > 0 ? .orange : .secondary)
                    .symbolEffect(.bounce, value: value)
                Text(value > 0 ? "\(value)" : "—")
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            Text(label)
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .glassSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.06), lineWidth: 1)
        )
        .animation(.snappy, value: value)
    }
}

#Preview {
    InsightsView()
        .environment(\.appAccent, .purple)
}
