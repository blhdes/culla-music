# Culla Music

A swipe-sorter for Apple Music — one song at a time. Swipe right to drop it onto a playlist, swipe left to dismiss it. The library, the “unsorted” bucket, and the dismissed pile are each their own review mode, so triage stays focused.

> Sibling project to **Culla** (a swipe-sorter for the Photos library). Same `@Observable` + SwiftData stack, same one-decision-at-a-time idea, applied to a different library.

---

## What it does

- **Three review modes**, picked from the Home screen:
  - **Library** — full library minus what the app has already touched.
  - **Unsorted** — songs not in any of your personal playlists (editorial / replay / personalMix / external are hidden by default).
  - **Dismissed** — the rejected pile, with an un-dismiss path.
- **Dismissed-mode cleanup menu** — long-press a dismissed card to see a preview of every playlist that song lives in, then **selectively strip it from any subset** of them (toggleable rows, all selected by default). Or pick **Forget dismissal** to un-dismiss without sorting. Destructive removals get a 6 s inline-snackbar Undo that also cancels the in-flight Apple Music task before reverting — no remove/add race.
- **Source playlist sorting** — point the deck at a specific playlist, then **COPY** songs into other playlists or **MOVE** them out as you go. Read-only sources (Apple-curated, shared, smart Favorites) are allowed too, locked to copy.
- **Up-swipe = Loved** — pull a card upward to drop the song into a "Loved" playlist. Defaults to a Culla-created *Culla Loves* (auto-created on first up-swipe); any of your own playlists can be picked as the target in Settings.
- **Hot-clip preview** (optional) — plays Apple Music's curated ~30s preview instead of streaming from 0:00. Faster triage, no 20-second intro to skip.
- **Scrubbable progress bar** with haptic ticks; cross-fades on track change.
- **Playlist membership chips** — small pills under the artist tell you which playlists the current song already lives in, so you don't re-sort what's already filed. The Loved chip is marked with a ♥.
- **Settings sheet** — theme (System/Light/Dark), sidebar accent palette, haptics master toggle, author-name override for created playlists, read-only-playlist scope toggle, up-swipe Loved-playlist target.
- **Undo history** — every swipe is reversible, including the playlist write on Apple Music's side. Failed remote writes roll back the local state too, so a swipe that didn't reach Apple Music leaves no trace.

---

## Requirements

- **iOS 17 or later** on the runtime device (iOS 26 SDK for development).
- An **Apple Music subscription** on the signed-in account. Without one, you'll get 30s previews instead of full songs but the swipe / sort flow still works.
- **Xcode 16.2 or later** with the iOS 26 simulators installed.
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

## Project layout

```
CullaMusic/
├── CullaMusic.xcodeproj/
└── CullaMusic/
    ├── CullaMusicApp.swift
    ├── Models/        — Playlist, SortedSong, DismissedSong, SwipeConfig
    ├── Services/      — MusicLibraryService (MusicKit, players, playlist CRUD)
    ├── ViewModels/    — MusicSwipeViewModel (deck state) + extracted coordinators:
    │                    UndoCoordinator, MembershipIndex, LovedPlaylistResolver,
    │                    DismissedDateStore
    ├── Views/         — Home, Swipe, Sidebar, Manage, Settings sheets
    ├── Helpers/       — AccentPalette, Haptics, shared modifiers
    └── Assets.xcassets/
```

See `AGENTS.md` for the contributor-side guide (conventions, build commands, commit style).

---

## Tech stack

- **SwiftUI** + `@Observable` for state (no Combine, no TCA).
- **SwiftData** for local persistence (`SortedSong`, `DismissedSong`, `Playlist` rows).
- **MusicKit** for Apple Music access — `MusicLibraryRequest` for library reads, `MusicLibrary.shared` for playlist edits, `Playlist.with([.tracks])` for membership queries.
- **`ApplicationMusicPlayer`** for full-song playback; **`AVPlayer`** for hot-clip previews (with an `AVMutableAudioMix` volume ramp to avoid boundary clicks).

---

## Status

MVP plus three polish phases. Functional end-to-end on iOS 26 simulators and on physical devices. On-device behavioral coverage continues — see the `Projects/Culla-Music/Phases/` notes for what's verified and what's still pending.

---

## License

Private project. No license granted — all rights reserved by the author.
