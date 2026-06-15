# Culla Music

A swipe-sorter for Apple Music — one song at a time. Swipe right to drop it onto a playlist, left to dismiss, up to love, down to share. The library, the “unsorted” bucket, and the dismissed pile are each their own review mode, so triage stays focused.

> Sibling project to **Culla** (a swipe-sorter for the Photos library). Same `@Observable` + SwiftData stack, same one-decision-at-a-time idea, applied to a different library.

---

## What it does

- **Three review modes**, picked from the Home screen:
  - **Library** — full library minus what the app has already touched.
  - **Unsorted** — songs not in any of your personal playlists (editorial / replay / personalMix / external are hidden by default).
  - **Dismissed** — the rejected pile, with an un-dismiss path.
- **Home art carousel** — the hero on Home is a scrubbable fan of the next few covers: drag across it to glance ahead, tap it to open a fullscreen center-anchored carousel of every cover in the current deck (in the chosen sort order). Both the fan and the carousel cover **every source** — the Library / Unsorted / Dismissed modes *and* a picked playlist or artist; a scoped deck pins the playlist cover (or artist photo) on top and scrubs the collection's own tracks behind it (no cover image → the tracks scrub on their own). In the carousel, drag/scroll snaps to the nearest cover, side-tap snaps it to centre and starts its preview, centre-tap toggles play/pause. The currently-centred song is the seed for the swipe session — tap **Start Cullaing** from inside the carousel and the preview keeps playing through the morph into the swipe card.
- **Dismissed mode + History sheet** — review what you've rejected; swipe right to un-dismiss into a playlist. A separate **History sheet** logs every past sort, love, and dismissal with **swipe-to-undo per row** (rows deep-link to the song in Apple Music). Dismissed **catalog tracks resurface here too** — each dismissal records whether the song was catalog-only, so the deck resolves it from the catalog rather than the library.
- **Source playlist sorting** — point the deck at a specific playlist, then **COPY** songs into other playlists or **MOVE** them out as you go. Read-only sources (Apple-curated, shared, smart Favorites) are allowed too, locked to copy. Scoping to a playlist also surfaces its **catalog tracks that aren't in your library yet**, so an Apple-curated or editorial playlist can be auditioned for new music (the All-Library, Unsorted, and Artist decks stay library-only).
- **Per-playlist library filter** — the Manage Playlists sheet has two segments: **Sidebar** (which playlists appear as drop targets) and **Filter queue** (which playlists' songs to hide from `.library` sessions). The filter is lenient — a song only disappears when *every* playlist it belongs to is filtered, so already-sorted tracks drop out of the library deck without hiding songs you still need to triage. Both segments carry a **sort chip** with independent saved preferences (Sidebar defaults to your real sidebar order). Culla-created playlists can be renamed with a swipe in the sidebar list.
- **Up-swipe = Loved** — pull a card upward to drop the song into a "Loved" playlist. Defaults to a Culla-created *Culla Loves* (auto-created on first up-swipe); any of your own playlists can be picked as the target in Settings.
- **Down-swipe = Share** — flick a card downward to open the system share sheet for the current song. The card stays put (sharing isn't a sort action), so the same song is still on screen behind the sheet.
- **Date jump** — fast-forward the deck to a point in time: from the carousel, jump to a *library-add date* and seed the swipe session from songs added around then; inside a Library / Unsorted / Artist session you can opt into the same jump. Useful for triaging "everything I added last summer" without scrolling.
- **Auto-play on swipe** (default on) — each new card's preview starts the moment the card lands. Toggle off in Settings to keep the swipe screen silent until you tap play. Combine with **Hot-clip preview** for Apple Music's curated ~30 s preview instead of streaming from 0:00.
- **Scrubbable progress bar** with a playhead dot and haptic ticks; the fill holds its position on pause (no retract) and resumes from where you left off, and cross-fades on track change.
- **Album + year on the card** — an optional line under the title shows the album and release year when available. The now-playing title marquee-scrolls when it's too long to fit.
- **Album liner notes** — an info button on the inline album label opens a sheet with the album sleeve and Apple Music's editorial notes about the record (the section hides when there are none).
- **Playlist membership chips** — small pills under the artist tell you which playlists the current song already lives in, so you don't re-sort what's already filed. Chips pick up the song's own accent colour (kept legible on dark album art), and the Loved chip is marked with a ♥.
- **Artist hub** — info button on the swipe card opens a sheet with the artist's top songs, similar artists, an **About** blurb, and a Google fallback (branded, multi-color "G"). Tapping a similar artist drills deeper without dismissing back to the deck.
- **Artist "About"** — a one-paragraph bio pulled from Wikipedia, shown in a collapsible card: tap to expand the full text (one-way), tap again to open the article. Names that collide with something else ("Air" the band vs. the gas) are disambiguated through MusicBrainz → Wikidata; when no reliable artist match exists the section hides rather than show a wrong bio. Bios are cached on disk for a week (misses included, so the long tail isn't re-fetched every open). When Apple Music has its own editorial notes for the artist, they sit above the Wikipedia bio.
- **Settings sheet** — theme (System/Light/Dark), a 33-swatch accent palette (contrast-aware labels), haptics master toggle, auto-play on swipe, hot-clip preview, author-name override for created playlists, read-only-playlist scope toggle, up-swipe Loved-playlist target.
- **Content-shaped loading** — Home's hero deck, playlist back cards, count badges, and the artist sheet load as shimmering **skeletons in the exact shape of the real layout**, so covers and text sharpen into place instead of popping in. The shimmer is phase-synced across every bone and freezes under Reduce Motion.
- **First-run guide** — a brand splash gated on real content loading (no empty-chrome flash), then a one-time, looping swipe-guide overlay that previews your real next cover and animates the drag hints (lean right to file, up to love). Skipped under Reduce Motion; it never replays once seen.
- **Undo history** — every swipe is reversible, including the playlist write on Apple Music's side. Failed remote writes roll back the local state too, so a swipe that didn't reach Apple Music leaves no trace.
- **Localized in eight languages** — the entire UI ships as a String Catalog in English, Spanish, German, French, Italian, Japanese, Brazilian Portuguese, and Simplified Chinese. Counts and relative-time strings use each locale's plural rules, and the Apple Music permission prompt is localized too. Switch the app's language independently from the system in **iOS Settings → Apps → CullaMusic → Language**.

---

## Requirements

- **iOS 17 or later** on the runtime device (the app target deploys to 17.0; built against the iOS 26.2 SDK).
- An **Apple Music subscription** on the signed-in account. Without one, you'll get 30s previews instead of full songs but the swipe / sort flow still works.
- **Xcode 26.2 or later** with the iOS 26 simulators installed.
- A Development signing cert for the App ID's team — MusicKit catalog requests fail without it, even when the Apple Music UI works fine. See `Dev-Insights/MusicKit Catalog API Cert Setup 2026-05-11.md` in the project's notes for details.

---

## Build & run

```bash
# Open in Xcode
open CullaMusic/CullaMusic.xcodeproj

# Or build from the command line for a simulator:
xcodebuild \
  -project CullaMusic/CullaMusic.xcodeproj \
  -scheme CullaMusic \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -configuration Debug build
```

On first launch the app asks for Apple Music authorization. Grant it once and the deck loads.

---

## Portfolio screenshots

A single dev flag, `cullaScreenshotMode` (top of `Views/PlaylistSidebarView.swift`, default `false`), prepares the app for clean marketing/portfolio shots without risking real data. When `true`:

- the right-drag **sidebar** shows dressed-up sample playlists (genre names + photo covers) instead of your live playlists;
- the swipe deck is **guarded** so no release can dismiss / love / assign / share — you can frame the shot freely and never lose a song.

The sample covers are referenced by name (`shot_*`) and are **not** bundled. To use them, drop matching images into `Assets.xcassets` (the names live in the `samples` array), flip the flag to `true`, shoot, then flip it back to `false`.

---

## Project layout

```
CullaMusic/
├── CullaMusic.xcodeproj/
└── CullaMusic/
    ├── CullaMusicApp.swift
    ├── Models/        — Playlist, SortedSong, DismissedSong, SwipeConfig,
    │                    QueueFilterStore (per-playlist library filter, @AppStorage)
    ├── Services/      — MusicLibraryService (MusicKit, players, playlist CRUD),
    │                    PlaylistTracksCache (actor-isolated membership cache),
    │                    CarouselSongFeed (covers for the Home carousel),
    │                    ArtistBioService + ArtistBioCache + MusicBrainzClient
    │                    (Wikipedia bios with MusicBrainz disambiguation)
    ├── ViewModels/    — MusicSwipeViewModel (deck state) + extracted coordinators:
    │                    UndoCoordinator, MembershipIndex, LovedPlaylistResolver,
    │                    DismissedDateStore
    ├── Views/         — Home (+ hero art stack / scrub carousel), Swipe + SongCard,
    │                    Sidebar, ArtistDetail (artist hub) + ArtistLoadingSkeleton,
    │                    SourceScopePicker, Manage / Settings / picker sheets
    ├── Helpers/       — GlassPanel + GlassSurface + SettingsCard (Liquid Glass / calm
    │                    primitives), LivingMeshBackground + HomeAmbientBackground,
    │                    AccentPalette + AccentEnvironment + AccentExtractor + Color+Contrast,
    │                    Transitions (hero morph), SortChip (shared glass sort menu),
    │                    SkeletonShape (shimmer loading bones), Haptics, LinearLoader,
    │                    SafariView, HTTP (shared User-Agent fetch)
    └── Assets.xcassets/
```

See `AGENTS.md` for the contributor-side guide (conventions, build commands, commit style).

---

## Tech stack

- **SwiftUI** + `@Observable` for state (no Combine, no TCA).
- **SwiftData** for local persistence (`SortedSong`, `DismissedSong`, `Playlist` rows).
- **MusicKit** for Apple Music access — `MusicLibraryRequest` for library reads, `MusicLibrary.shared` for playlist edits, `Playlist.with([.tracks])` for membership queries.
- **`ApplicationMusicPlayer`** for full-song playback; **`AVPlayer`** for hot-clip previews (with an `AVMutableAudioMix` volume ramp to avoid boundary clicks).
- **Wikipedia REST + MusicBrainz + Wikidata** for artist bios — all auth-free. MusicBrainz disambiguates by MBID (rate-limited to 1 req/sec via an actor gate, descriptive `User-Agent` on every call); results are cached to disk.

---

## Status

MVP plus five build phases — most recently a Liquid Glass design-language pass and a deliberate restraint pass back toward minimalism, followed by a polish round (richer swipe card, per-playlist library filter, scrubbable progress bar, catalog-track auditioning in the scoped/dismissed decks, sortable Manage Playlists segments, content-shaped loading skeletons, scrub-and-expand hero preview for every source (incl. a picked playlist/artist), iOS 26 glass/mesh fixes), followed by full localization into eight languages. Functional end-to-end on iOS 26 simulators and on physical devices. On-device behavioral coverage continues — see the `Projects/Culla-Music/Phases/` notes for what's verified and what's still pending.

---

## License

Private project. No license granted — all rights reserved by the author.
