# Culla Music × Spotify — execution plan

> **Status: PARKED (2026-11-12).** Culla stays Apple Music only until Spotify lets apps
> serve unlimited users. Nothing below has been started. Re-verify §1 before resuming.

Written 2026-11-12 by Claude (Fable 5.2) after reading the whole codebase and Spotify's
current developer rules. It is meant to be **executed later, step by step, by another
model (e.g. Opus 5.5) in Claude Code**, with Alejandro testing on his iPhone between steps.

---

## 0. The short version (plain language)

**Can Culla Music offer "Sign in with Spotify" to everyone on the App Store today? No.**

Spotify changed its rules in 2025–2026. An app made by an individual developer may only be
used by **5 Spotify accounts that the developer adds by hand**, and the developer must pay
for Spotify Premium. Opening an app to everyone ("extended quota") is reserved for
**registered companies whose service already has 250,000 monthly users**. Culla Music does
not qualify, and no amount of code changes that.

What *is* possible now:

1. **A personal Spotify edition** of Culla Music for you + up to 4 people you pick
   (a second app on your phone, built from the same code).
2. **Reshaping the code so a second music service plugs in cleanly.** Today the whole app
   speaks "Apple Music" directly. After this work it speaks to a neutral "music provider",
   and Apple Music is just the first one. If Spotify ever opens up — or you add another
   service — most of the work is already done.

So the plan is built in stages with **stop-and-decide gates**. You can stop after any gate
and keep everything that was built up to there.

| Stage | What you get | Risk to the live app | Can ship to App Store? |
|---|---|---|---|
| **A — Spike** | Proof on your own phone that login, reading, writing and playback work | None (separate app) | No |
| **B — Provider layer** | Same Apple Music app, cleaner inside | Medium (big refactor, no new features) | Yes, as a normal update |
| **C — Spotify provider** | Working Spotify edition for ≤ 5 accounts | None (separate app) | No |
| **D — Public release** | Spotify for everyone | — | **Blocked by Spotify's rules** |

**My recommendation:** do Stage A (cheap, tells you whether the Spotify experience is even
good). Only continue to B and C if you want the personal edition or want to be ready for
the future. Do not build D until Spotify's rules change or Culla qualifies.

---

## 1. Facts this plan depends on (verified 2026-11-11)

Spotify changed these rules three times in 18 months. **Executor: re-open each source before
relying on a fact — if a page says something different, stop and tell the user.**

> **Re-verified 2026-11-12 (Opus 5.5), before Stage A:** F1–F12 all still hold. Additions:
> Spotify allows only **one Development Mode Client ID per developer** (F2 blog);
> `external_ids` (ISRC) was removed in Feb 2026 and later **restored** (F4 guide);
> playlist items carry both `item` and the deprecated `track` (F7); the iOS SDK's auth doc
> confirms built-in PKCE (no backend) and accepts custom-scheme or universal-link redirects (F10).

| # | Fact | Source |
|---|---|---|
| F1 | Development Mode: max **5 allow-listed users** per app; the **app owner needs Premium** (app stops working if it lapses); non-allow-listed users can log in but every API call returns **403** | [Quota modes](https://developer.spotify.com/documentation/web-api/concepts/quota-modes) |
| F2 | Development Mode is for "learning, experimentation, and personal projects for **non-commercial** use" and "should not be relied on as a foundation for building or scaling a business" | [Blog 2026-02-06](https://developer.spotify.com/blog/2026-02-06-update-on-developer-access-and-platform-security) |
| F3 | Extended quota: **organizations only** (since 2025-05-15), legally registered business, launched service, **≥ 250k MAU**, key markets, review up to 6 weeks | [Quota modes](https://developer.spotify.com/documentation/web-api/concepts/quota-modes), [Blog 2025-04-15](https://developer.spotify.com/blog/2025-04-15-updating-the-criteria-for-web-api-extended-access) |
| F4 | Dev-mode endpoint changes (Feb 2026): playlist endpoints are now `/playlists/{id}/items` (not `/tracks`); playlist items readable **only for playlists the user owns or collaborates on**; create playlist is `POST /me/playlists`; batch `GET /tracks?ids=` removed (one `GET /tracks/{id}` per track); `GET /artists/{id}/top-tracks` removed; search `limit` max 10; `GET /me` no longer returns `product`, `email`, `country`; fields renamed `tracks`→`items`, `track`→`item` | [Feb 2026 migration guide](https://developer.spotify.com/documentation/web-api/tutorials/february-2026-migration-guide) |
| F5 | Dev-mode quota is shared across all of a developer's apps; quota errors are `429` with `"reason": "QUOTA_EXCEEDED"` (different from ordinary rate limiting) | [Blog 2026-07-23](https://developer.spotify.com/blog/2026-07-23-web-api-quota-updates) |
| F6 | `GET /me/tracks` (saved songs): scope `user-library-read`, `limit` ≤ 50, has `added_at` per item and a `total`; `preview_url` is deprecated/null | [Reference](https://developer.spotify.com/documentation/web-api/reference/get-users-saved-tracks) |
| F7 | `GET /playlists/{id}/items`: scope `playlist-read-private`, `limit` ≤ 50, 403 for playlists not owned/collaborative | [Reference](https://developer.spotify.com/documentation/web-api/reference/get-playlists-items) |
| F8 | Tokens: access token lasts 1 hour; refresh tokens have a **fixed 6-month lifetime** (refreshing does not extend it) → the user must log in again twice a year; `invalid_grant` = discard and re-login | [Refreshing tokens](https://developer.spotify.com/documentation/web-api/tutorials/refreshing-tokens) |
| F9 | Redirect URIs must be HTTPS (or loopback). Whether custom schemes (`myapp://`) still work is **contradictory** between Spotify's blog (yes) and community reports (`INVALID_CLIENT: Insecure redirect URI`). **Must be tested in Stage A.** | [Redirect URIs](https://developer.spotify.com/documentation/web-api/concepts/redirect_uri), [Blog 2025-02-12](https://developer.spotify.com/blog/2025-02-12-increasing-the-security-requirements-for-integrating-with-spotify) |
| F10 | Spotify iOS SDK (App Remote): Swift Package; does PKCE login itself with **no backend**; playback happens **inside the Spotify app** (must be installed); **Premium required** to play a specific track; "music must be playing when you connect"; disconnect when backgrounded | [ios-sdk README](https://github.com/spotify/ios-sdk), [auth.md](https://github.com/spotify/ios-sdk/blob/master/docs/auth.md) |
| F11 | Policy: no playback for non-Premium (IV.1); streaming apps must be non-commercial (IV.2 — Culla is free with no IAP, fine); **"Do not create any product or service which is integrated with streams or content from another service"** (III.5); no analysing Spotify content (III.13); no ML training (III.14); must offer an easy **disconnect** and delete the user's data then (I.1.2); must have a privacy policy describing the access (I.1.1); app name must not start with "Spot" | [Developer Policy](https://developer.spotify.com/policy) |
| F12 | Design rules: show the full Spotify logo next to Spotify content; link back with "OPEN SPOTIFY" / "PLAY ON SPOTIFY"; artwork must not be cropped, animated, blurred, overlaid with controls; corner radius 4px (8px on large devices); never put Spotify content next to another service's content. Official logo files: "Download Full Logo" on the page | [Design guidelines](https://developer.spotify.com/documentation/design) |

Consequences for Culla:

- **F1 + F3 → public launch is impossible today.** Everything below is the personal/dev edition plus future-proofing.
- **F11 III.5 → never mix services.** No Apple Music previews for Spotify songs, no Apple editorial notes on Spotify albums, no "copy my Spotify playlist to Apple Music". One provider at a time, in separate apps for now.
- **F12 → the swipe card breaks Spotify's artwork rules** (play disc and progress bar sit on the cover, 24pt corners, the card rotates). Irrelevant for a private build; a hard requirement for any public release (Stage D).
- **F10 → no 30-second "Hot Preview" on Spotify**, and playback needs Premium + the Spotify app. Free accounts get a silent deck with an "Open Spotify" link.
- Other services (TIDAL, Deezer) were **not** researched properly — a quick search found nothing reliable about their approval rules. If Spotify stays closed, researching TIDAL's developer platform is the next thing to try; Stage B makes any provider pluggable.

---

## 2. Rules for the executing model

Read `AGENTS.md`, the user's `~/.claude/CLAUDE.md`, and the memory index before starting. On top of those:

1. **One step at a time.** Each numbered step ends with a build. Do not start the next step with a red build.
2. **Build command (verified working, Xcode 27.2, no simulator involved):**
   ```bash
   xcodebuild -project CullaMusic/CullaMusic.xcodeproj -scheme CullaMusic \
     -configuration Debug -destination 'generic/platform=iOS' \
     CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -20
   ```
   Baseline on 2026-11-12: `** BUILD SUCCEEDED **`, zero warnings in project sources. Keep it that way.
   Once the second app exists (Stage A), run it again with `-scheme CullaMusicSpotify` — "build both schemes" below means exactly these two commands.
3. **Never run, boot or screenshot the simulator.** Never run `xcodebuild test`. The user tests every change on a physical iPhone. Steps marked 🧪 are his; stop there and wait.
4. **Never hand-edit `project.pbxproj`.** The project uses file-system-synchronized groups: any file created under `CullaMusic/CullaMusic/` is in the target automatically, and deleting a file removes it. Anything that needs project settings (new target, Swift package, capability, Info.plist keys) is a 👉 **user step in Xcode** — give exact click-by-click instructions, then verify by reading the pbxproj.
5. **Concurrency settings you must respect** (they are unusual): `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `SWIFT_APPROACHABLE_CONCURRENCY = YES`, Swift 5 language mode, `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES`.
   - Everything is `@MainActor` unless marked otherwise. Plain value types that cross actors (DTOs, domain structs, anything decoded inside an `actor`) must be declared `nonisolated struct …` — see `BucketStats` in `AccentExtractor.swift` and `MembershipIndex.ArtistCountsSnapshot` for the house pattern.
   - Each file must `import` the module that declares every member it touches (e.g. using `id.rawValue` on a `MusicItemID` needs `import MusicKit` in that file).
6. **Commits:** only when the user asks. Conventional Commits (`feat:`, `fix:`, `refactor:`). Ask once at the start of Stage B whether to work on a branch — recommend `provider-layer`, because `main` is what gets archived for the App Store.
7. **SwiftData is the user's sorting history. Do not change stored properties** of `Playlist`, `SortedSong`, `DismissedSong` (no renames, no removals, no new non-optional fields without a default). The app `fatalError`s at launch if the store can't open. This plan never requires a schema change.
8. **Hard-won rules already in memory — do not relearn them the painful way:**
   - Library song IDs and catalog song IDs are different namespaces. Never re-resolve one as the other.
   - Library artwork must render through `ArtworkImage` (MusicKit), never `AsyncImage`.
   - Playlist editability is re-derived on every sync, never stored as a sticky flag.
   - Reconcilers (`SortedSongReconciler`, `DismissedSongReconciler`) may only run on evidence from a fetch that **succeeded and was non-empty**. A failed or empty fetch proves nothing.
   - Swipe-card pills are flat fills (no glass); the card is full-screen (animate opacity or the artwork tile, never whole-card geometry).
   - Do not add the `com.apple.developer.musickit` entitlement.
9. **Logos:** never draw a brand mark by hand. Spotify's logo must be the official file downloaded from the design-guidelines page (F12).
10. **Talk to the user like a beginner.** Short messages, plain words, explain the trade-off not the code.

---

## 3. Where the code is today (so you know what you're moving)

- `Services/MusicLibraryService.swift` (~1,600 lines) is a singleton doing **everything** Apple: authorization, library paging, playlists (read/create/rename/add/remove), artist & album lookups, ID resolution, and playback (`ApplicationMusicPlayer` + `AVPlayer` hot clips). `MusicLibraryService.shared` appears on about 40 lines in 16 files.
- MusicKit **model types** leak everywhere: `Song` (82 mentions outside the service), `Artist` (38), `Artwork` (25), `ArtworkImage` (21), `MusicItemID` (22), `Album` (13). 29 files `import MusicKit`.
- MusicKit **requests** outside the service (these are the real coupling to cut first):
  - `Services/CarouselSongFeed.swift` — `loadNextLibraryPage` builds a `MusicLibraryRequest<Song>`.
  - `Views/HomeView.swift` — `HomeViewModel.recomputeCounts` walks the whole library.
  - `Views/HomeHeroArtStack.swift` — `fetchSongArtwork`, `fetchUnexcludedLibraryArtworks`, `fetchRecentlyDismissedArtworks` (per-ID lookups + a limit-1 probe).
  - `Helpers/AccentExtractor.swift` — `resolveHTTPSArtworkURL` does catalog ISRC/search requests.
  - `Views/RootView.swift`, `Views/AuthGateView.swift` — `MusicAuthorization.Status`.
- The codebase **already shadows a MusicKit name on purpose**: the SwiftData model is called `Playlist`, and Apple's is written `MusicKit.Playlist`. Stage B extends that same convention to `Song`, `Artwork`, `Artist`, `Album`, `Track`, `ArtworkImage`. That is what keeps the refactor small: most view code keeps compiling unchanged because the names and member names stay the same.
- Provider-neutral logic that must stay shared (not copied per provider): `deckExclusionSet`, `queueFilterExclusions`, `scopeExclusionSet`, `libraryAddDateIsPrefix`, both reconcilers, `PlaylistSyncer`, `MembershipIndex`, `QueueFilterStore`, `UndoCoordinator`, `LovedPlaylistResolver`.

---

## 4. Stage A — Spike (prove it on a real phone first)

**Goal:** answer five questions with Alejandro's own Spotify account before touching the live app's architecture.

| Q | Question | Why it decides things |
|---|---|---|
| A1 | Does login work, and which redirect URI style does Spotify accept? | F9 is contradictory |
| A2 | Can we read saved songs (with add dates) and playlists? | Core of every deck |
| A3 | Can we create a playlist, add a track, remove it? | Core of sorting; removal is *better* than on Apple Music |
| A4 | Is playback through the Spotify app pleasant while Culla stays on screen? | "Hear before you decide" is the product |
| A5 | How heavy is a full library read (requests, seconds, any 429)? | Sizes the caching work in Stage C |

Everything in this stage lives in a **second app target** so the App Store app is untouched.

### A0 — 👉 User setup (about 20 minutes)

1. **Spotify dashboard** (needs your Premium account): [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard) → Create app. Name: `Culla Music (dev)` — must not start with "Spot". APIs used: *Web API* and *iOS*. Redirect URIs: add **both** `https://culla.app/music/spotify-callback` and `culla-spotify://callback` (if the dashboard refuses the second one, note the exact error — that answers half of A1). Bundle ID: `app.culla.music.spotify`. Copy the **Client ID** (it is not a secret).
2. Dashboard → your app → Settings → **User Management**: add your own Spotify account (name + email).
3. **Xcode — duplicate the target:** project navigator → blue project icon → under TARGETS right-click **CullaMusic** → *Duplicate*. Rename the copy `CullaMusicSpotify`. Then for that target:
   - *Build Settings* → **Product Bundle Identifier** = `app.culla.music.spotify`; **Product Name** = `CullaSpotify`.
   - *Build Settings* → search "Active Compilation Conditions" → add `SPOTIFY` to **both** Debug and Release.
   - *Info* tab → add **URL Types** entry with URL Scheme `culla-spotify`; add row **Queried URL Schemes** (`LSApplicationQueriesSchemes`) with one item `spotify`.
   - *General* → Display Name `Culla Spotify`.
   - Xcode also created a scheme named "CullaMusic copy": *Product → Scheme → Manage Schemes* → rename it `CullaMusicSpotify`.
4. **Add the SDK:** *File → Add Package Dependencies…* → `https://github.com/spotify/ios-sdk` → add product **SpotifyiOS** to target **CullaMusicSpotify only** (untick CullaMusic).
5. Tell the model the Client ID and whether step 1 accepted both redirect URIs.

**Executor checks after A0:** `xcodebuild -list -project CullaMusic/CullaMusic.xcodeproj` shows both schemes; both build. Read the pbxproj to confirm `SPOTIFY` is set only on the new target and the package is linked only there. If Xcode created an `Info.plist` file inside `CullaMusic/CullaMusic/` and the build warns that it is "copied as a resource", ask the user to untick it under *Target Membership* in the File inspector. Remove `Package.resolved` from `.gitignore` (an app should commit it so builds are reproducible).

**Golden rule for the shared folder:** every Spotify file is wrapped top-to-bottom in `#if SPOTIFY … #endif`. The App Store target has no `SPOTIFY` flag and no SDK, so it must never see Spotify symbols. After every step, build **both** schemes.

### A1 — Networking core (reused in Stage C, not throwaway)

Create under `CullaMusic/CullaMusic/Services/Spotify/` (all `#if SPOTIFY`):

- `SpotifyConfig.swift` — `clientID`, `redirectURL`, scopes: `user-library-read`, `playlist-read-private`, `playlist-read-collaborative`, `playlist-modify-private`, `playlist-modify-public`, `app-remote-control`.
- `SpotifyTokenStore.swift` — Keychain (`kSecClassGenericPassword`, service `app.culla.music.spotify`) holding access token, expiry, refresh token, and the date of authorization (for the 6-month re-login, F8). Never `UserDefaults`.
- `SpotifyAuth.swift` — `@MainActor @Observable` class wrapping the SDK's `SPTSessionManager` (PKCE, no backend). Exposes `state` (`.signedOut` / `.signedIn`), `signIn()`, `signOut()`, `validAccessToken() async throws -> String` (renews when < 60 s from expiry; on `invalid_grant` clears the store and flips to `.signedOut`). Redirects arrive through SwiftUI `.onOpenURL` on the root view.
  **Before writing this file, read the SDK's headers and `docs/auth.md` at the version SPM resolved** (`find` the `SpotifyiOS.xcframework` under the derived-data `SourcePackages` folder). Do not trust class or method names from memory or from this plan.
- `SpotifyDTO.swift` — `nonisolated` `Decodable, Sendable` structs: `Paging<T>`, `SavedTrack`, `TrackDTO`, `AlbumDTO`, `ArtistRefDTO`, `ImageDTO`, `PlaylistDTO`, `PlaylistItemDTO`, `UserDTO`, `SnapshotDTO`, `APIErrorDTO`. Decode **defensively**: playlist payloads may use the new keys (`items`, `item`) or the old ones (`tracks`, `track`) — accept either (custom `init(from:)`). Mark every optional field optional; dev-mode responses drop fields (F4).
- `SpotifyAPIClient.swift` — an `actor`. One request at a time with a small gap (start at 100 ms); `get/post/put/delete` helpers; bearer token from `SpotifyAuth`; on `401` refresh once and retry; on `429` read `Retry-After`, and if the body says `QUOTA_EXCEEDED` throw a distinct `SpotifyError.quotaExceeded` (do **not** retry); on `403` throw `SpotifyError.notAllowListed` (the account isn't one of the 5). Log method, path, status and duration with `print` — never the token.

### A2 — Spike screen

`Views/Spotify/SpotifySpikeView.swift` (`#if SPOTIFY`), shown instead of `SplashGate()` in `CullaMusicApp` under `#if SPOTIFY`. A plain `List` with one button per experiment and a scrolling log of results. It is a lab bench — do not design it.

1. **Sign in / Sign out** → shows the user id from `GET /me`.
2. **Read library** → `GET /me/tracks?limit=50`, show `total`, first 5 titles with `added_at`. Then "Walk 500": page 10 times, show request count, total seconds, any 429.
3. **Read playlists** → `GET /me/playlists?limit=50`; for each: name, owner id == me?, `snapshot_id`, item total. Then load items of the first owned playlist via `GET /playlists/{id}/items`.
4. **Write test** → `POST /me/playlists` (`"Culla Spike"`, private) → `POST /playlists/{id}/items` with one saved-track URI → read back → `DELETE /playlists/{id}/items` with that URI → read back. Leave the empty playlist; tell the user to delete it in Spotify.
5. **Playback test** (App Remote): Connect → Play a URI → Pause → Resume → Seek +30 s → show live position. Also log `canPlayOnDemand` from the user capabilities API. Try each of these starting conditions and write down what happens: Spotify app closed; Spotify open but idle; Spotify already playing; phone locked and unlocked mid-test.

### 🧪 Gate 1 — Alejandro tests, then decides

Record the answers in this file under a new "Spike results" heading:

- A1: which redirect URI works (custom scheme / https / both)? If only https works, a tiny static page on `culla.app/music/spotify-callback` plus the *Associated Domains* capability is needed — that is a new 👉 user step; write its instructions then.
- A4, the big one: how many app-switches to Spotify per session? Does the music keep going when swiping fast? Is it good enough to "sort by feel"?
- A5: seconds and requests for 500 songs.

**Decide:** stop here (nothing in the live app changed) · or continue to Stage B.

---

## 5. Stage B — Provider layer (Apple Music only, behaviour identical)

**Goal:** the app talks to a neutral `MusicProvider`. Apple Music is the only implementation. Nothing the user can see changes. This is the risky stage — it rewires a shipped app — so it is cut into four steps that each build and each end in a device check.

Before starting: read these files completely — `Services/MusicLibraryService.swift`, `ViewModels/MusicSwipeViewModel.swift`, `Services/CarouselSongFeed.swift`, `Views/HomeHeroArtStack.swift` (the *Fetch* section), `Views/HomeView.swift` (`HomeViewModel`), `Helpers/AccentExtractor.swift`, `Models/MovementSnapshot.swift`, `Helpers/PlaylistSyncer.swift`, `ViewModels/LovedPlaylistResolver.swift`.

### B1 — Give Apple's types unambiguous names inside the Apple file (no behaviour change)

1. Add `Services/AppleMusic/AppleMusicAliases.swift`:
   ```swift
   import MusicKit

   // Unambiguous names for Apple's types. Step B3 introduces app-owned types
   // called Song / Artwork / Artist / Album / Track (same trick the SwiftData
   // `Playlist` already plays against `MusicKit.Playlist`), so Apple-specific
   // code must stop using the bare names first.
   typealias AMSong = MusicKit.Song
   typealias AMArtwork = MusicKit.Artwork
   typealias AMArtist = MusicKit.Artist
   typealias AMAlbum = MusicKit.Album
   typealias AMTrack = MusicKit.Track
   typealias AMPlaylist = MusicKit.Playlist
   ```
2. In **`MusicLibraryService.swift` only**, replace whole words: `Song`→`AMSong`, `Artwork`→`AMArtwork`, `Artist`→`AMArtist`, `Album`→`AMAlbum`, `MusicKit.Track`→`AMTrack`, `MusicKit.Playlist`→`AMPlaylist`. Whole-word matching matters: `SortedSong`, `DismissedSong`, `resolveArtist`, `artistNotFound`, `ArtistCountsSnapshot` must **not** change.
3. Build. Because these are aliases of the very same types, every caller still compiles.

### B2 — Move every MusicKit *request* behind the service (no behaviour change)

Add to the service (still Apple-typed for now):

```swift
struct LibraryPage { let songs: [AMSong]; let reachedEnd: Bool }

/// One page of library songs ordered by add date. `reachedEnd` is true when
/// the page came back shorter than `limit` (or empty).
func libraryPage(offset: Int, limit: Int = 100, ascending: Bool) async throws -> LibraryPage

/// Exact-ID library lookup. `nil` = the request SUCCEEDED and the song is not
/// there (authoritative). A thrown error = no evidence either way.
func librarySong(id: MusicItemID) async throws -> AMSong?

/// A plain https artwork URL for pixel sampling. Moved verbatim from
/// AccentExtractor.resolveHTTPSArtworkURL (artwork URL → ISRC → title+artist search).
func fetchableArtworkURL(for song: AMSong, pixelSize: Int) async -> URL?
```

Then replace the inline requests at these sites, keeping each loop's logic exactly as it is (only the "get a page" / "look up one ID" line changes):

| File | Function | Becomes |
|---|---|---|
| `Services/CarouselSongFeed.swift` | `loadNextLibraryPage` | `libraryPage(offset:limit:ascending:)`; set `isExhausted` from `reachedEnd` |
| `Views/HomeView.swift` | `HomeViewModel.recomputeCounts` | `libraryPage` in the same `while` loop; keep `offset > 0` as the "walk saw at least one song" evidence and keep `Task.checkCancellation()` |
| `Views/HomeHeroArtStack.swift` | `fetchSongArtwork` | `librarySong(id:)?.artwork` |
| `Views/HomeHeroArtStack.swift` | `fetchUnexcludedLibraryArtworks` | `libraryPage` |
| `Views/HomeHeroArtStack.swift` | `fetchRecentlyDismissedArtworks` | in each task-group child: `try await MusicLibraryService.shared.librarySong(id:)` → found / `.missing` (nil) / `.failed` (throw). The limit-1 probe becomes `libraryPage(offset: 0, limit: 1, …)`. **Keep the three-way outcome and the probe** — they are what stops a cold, empty library read from voiding real dismissals |
| `Helpers/AccentExtractor.swift` | `resolveHTTPSArtworkURL` | delete; call `fetchableArtworkURL(for:pixelSize: 64)` |

Build. 🧪 **Device check B2:** Home hero in Library / Unsorted / Dismissed; open the carousel and scroll far enough to load more; count badges settle; card tint colours still appear.

### B3 — The flip: app-owned model types

Add `Models/Domain/` with these `nonisolated` value types. They deliberately reuse Apple's **names and member names**, so the 80+ places that say `song.title`, `song.id.rawValue`, `ArtworkImage(artwork, width:height:)` keep compiling. Use the **synthesized** `Equatable`/`Hashable` (do not hand-write id-only equality — some views rely on `onChange` noticing content changes).

```swift
import Foundation
import CoreGraphics
import MusicKit   // only for MusicItemID (kept as the app-wide string ID type) and the wrapped Apple values

nonisolated enum ProviderID: String, Codable, Sendable { case appleMusic, spotify }  // raw values are persisted: never rename

nonisolated struct Song: Identifiable, Hashable, Sendable {
    let id: MusicItemID
    let title: String
    let artistName: String
    let albumTitle: String?
    let artwork: Artwork?
    let duration: TimeInterval?
    let releaseDate: Date?
    let libraryAddedDate: Date?
    let genreNames: [String]
    let isrc: String?
    /// Opens this song in its own service (Apple: catalog URL, else an Apple Music
    /// search link — the logic now in Song+AppleMusicLink.swift; Spotify: open.spotify.com).
    let externalURL: URL
    let source: Source
    enum Source: Hashable, Sendable {
        case appleMusic(MusicKit.Song)
        case spotify(uri: String)
    }
}

nonisolated enum Artwork: Hashable, Sendable {
    case appleMusic(MusicKit.Artwork)
    case remote(RemoteArtwork)            // plain https images (Spotify)
    var backgroundColor: CGColor? { … }   // Apple: artwork.backgroundColor; remote: nil
    func url(width: Int, height: Int) -> URL? { … } // Apple: artwork.url(width:height:); remote: smallest image ≥ width
}
nonisolated struct RemoteArtwork: Hashable, Sendable { let images: [Sized]; struct Sized: Hashable, Sendable { let url: URL; let width: Int? } }

nonisolated struct Artist: Identifiable, Hashable, Sendable {
    let id: MusicItemID; let name: String; let artwork: Artwork?
    let genreNames: [String]?; let url: URL?
    var topSongs: [Song]?; var similarArtists: [Artist]?
    let source: Source   // .appleMusic(MusicKit.Artist) / .spotify
}
nonisolated struct Album: Identifiable, Hashable, Sendable {
    let id: MusicItemID; let title: String; let artistName: String; let artwork: Artwork?
    let copyright: String?; let releaseDate: Date?; let trackCount: Int
    let source: Source   // .appleMusic(MusicKit.Album) / .spotify
}
nonisolated struct Track: Identifiable, Hashable, Sendable {   // one row of an album tracklist
    let id: MusicItemID; let title: String; let duration: TimeInterval?; let trackNumber: Int?
    let song: Song?      // nil for music videos — replaces `if case .song(let s) = track`
}
nonisolated struct RemotePlaylist: Identifiable, Hashable, Sendable {
    let id: String; let name: String
    let isEditable: Bool            // accepts adds — Apple: computeEditability(for:)
    let versionToken: String?       // changes when contents change — Apple: lastModifiedDate; Spotify: snapshot_id
}
```

Plus `Views/Components/ArtworkImage.swift` — a SwiftUI view with the **same initializer** as Apple's, so no call site changes:

```swift
struct ArtworkImage: View {
    init(_ artwork: Artwork, width: CGFloat, height: CGFloat)
    // .appleMusic → MusicKit.ArtworkImage(a, width:, height:)   ← must stay MusicKit's view (library artwork rule)
    // .remote     → RemoteArtworkImage: URLSession + NSCache<NSURL, UIImage>, transparent while loading
}
```

And `Services/AppleMusic/AppleMusicMapping.swift` — `extension Song { init(_ s: AMSong) }` and the same for `Artwork`, `Artist`, `Album`, `Track`, plus a throwing `var appleMusicSong: AMSong` (throws `MusicLibraryError.wrongProvider` for non-Apple songs).

Now convert the **service's public surface** to these types: map `AMSong → Song` at every `return`, unwrap `Song → AMSong` at every input (`addSong`, `removeSong`, `playPreview`, `resolveArtist`, `resolveAlbum`, …). Internal caches stay Apple-typed. `refreshUserPlaylists()` and `createPlaylist(name:)` return `RemotePlaylist`; `PlaylistSyncer` and `LovedPlaylistResolver` read `.id`, `.name`, `.isEditable` from it.

Then build and **let the compiler be the checklist**. Expected consumer edits are few:

- `Views/AlbumDetailSheet.swift`: `[MusicKit.Track]` → `[Track]`; `if case .song(let song) = track` → `track.song`.
- `Song.appleMusicLinkURL` → `externalURL` (3 call sites: `MusicSwipeView`, `HistorySheet` ×2); delete `Helpers/Song+AppleMusicLink.swift`.
- `Helpers/PlaylistSyncer.swift`, `ViewModels/LovedPlaylistResolver.swift`: use `RemotePlaylist`.
- `ViewModels/ArtistLibraryStore.swift`, `SourceScopePickerSheet`, `ManagePlaylistsSheet`: should compile as-is (same member names).

If the error count is in the hundreds, the shadowing isn't working — stop and re-check that B1 was applied only to the service file and that the new types are spelled exactly `Song`, `Artwork`, `Artist`, `Album`, `Track`, `ArtworkImage`.

🧪 **Device check B3 — the full regression list in §8.** This is the step that can break things.

### B4 — Protocol, rename, registry

1. `Services/MusicProvider.swift`:
   ```swift
   @MainActor
   protocol MusicProvider: AnyObject, Observable {
       var id: ProviderID { get }
       var brand: ProviderBrand { get }
       var capabilities: ProviderCapabilities { get }

       // Auth
       var authState: ProviderAuthState { get }
       @discardableResult func requestAuthorization() async -> ProviderAuthState
       func signOut() async                       // Apple: no-op

       // …then every public member the service has today, in domain types:
       // library paging + cursors, libraryPage, librarySong, libraryAddedDateSpan,
       // artists (refreshLibraryArtists, artistLibrarySongs, fetchAllArtistTrackCounts, artwork(forArtistID:)),
       // playlists (refreshUserPlaylists, artwork(forPlaylistID:), lastModifiedDate(forPlaylistID:),
       //            createPlaylist, renamePlaylist, addSong, removeSong, loadPlaylistSongs,
       //            fetchAllPlaylistData, scopeSongs),
       // resolution (resolveSongs ×2, isInLibrary, catalogPresence),
       // hub (resolveArtist, loadArtistDetail, loadArtistEditorial, resolveAlbum, loadAlbumTracks, loadAlbumEditorial),
       // artwork (fetchableArtworkURL),
       // playback (isPlayingPreview, nowPlayingSongID, playbackPosition, playbackDuration,
       //           playPreview, stopPreview, pausePreview, resumePreview, seek)
   }
   ```
   `ProviderAuthState` is `notDetermined / denied / restricted / authorized` — the same four cases as `MusicAuthorization.Status`, so `RootView` and `AuthGateView` switch statements map one-to-one.
2. Put the provider-**neutral** rules in `extension MusicProvider` (default implementations, written once): `deckExclusionSet(for:modelContext:)`, `queueFilterExclusions()`, `scopeExclusionSet(includeDismissed:modelContext:)`, and the thin wrappers `fetchPlaylistSongIDs` / `fetchPlaylistMembershipIndex`. They only combine SwiftData, `QueueFilterStore` and provider calls.
3. `git mv Services/MusicLibraryService.swift Services/AppleMusic/AppleMusicProvider.swift`; rename the class to `AppleMusicProvider`; conform. Its `brand`: service name "Apple Music", open-link label "Open in Music". Its `capabilities` — see the table in §6.
4. `Services/Providers.swift`:
   ```swift
   @MainActor
   enum Providers {
       #if SPOTIFY
       static let active: any MusicProvider = SpotifyProvider.shared   // Stage C
       #else
       static let active: any MusicProvider = AppleMusicProvider.shared
       #endif
   }
   ```
   Until Stage C exists, the `#if SPOTIFY` branch can also point at `AppleMusicProvider.shared` so both schemes keep building.
5. Replace the token `MusicLibraryService.shared` → `Providers.active` (about 40 lines) and the type `MusicLibraryService` → `any MusicProvider` in stored properties and initializers (`MusicSwipeViewModel`, `CarouselSongFeed`, `MembershipIndex`, `LovedPlaylistResolver`, `HistoryStore`, `InsightsModel`). Inside task-group closures write `await Providers.active.method(…)` instead of capturing the provider.
6. `RootView` / `AuthGateView`: use `ProviderAuthState`; take the service name and the privacy line from `brand`.

Build both schemes. 🧪 **Device check B4:** quick pass of §8 (launch, one session with each gesture, one playlist write + undo, playback, History).

### 🧪 Gate 2

Stage B can be shipped as an ordinary App Store update (it contains no Spotify code). **Recommended: ship it and let it sit in real use for a week before starting Stage C**, so any regression is blamed on the right change.

---

## 6. Stage C — Spotify provider (dev edition, ≤ 5 accounts)

All files `#if SPOTIFY`, under `Services/Spotify/`. The Spotify app has its own bundle ID, so its SwiftData store, `UserDefaults` and cache files are automatically separate from the Apple Music app — **no data migration, no per-provider namespacing** in this stage.

### Feature map (drives `ProviderCapabilities`)

| Culla feature | Apple Music | Spotify (dev mode) | Capability flag |
|---|---|---|---|
| "Library" deck | library songs by add date | **Liked Songs** (`/me/tracks`, `added_at`) | — |
| Drop-target playlists | playlists that accept adds | playlists the user **owns** or collaborates on | — |
| Remove from playlist / Move out / real Undo | only playlists Culla created | **any owned playlist** | `removalRequiresAppCreatedPlaylist` (Apple true, Spotify false) |
| Rename playlist | only Culla-created | any owned playlist | same flag |
| Sort from a read-only / curated playlist | yes | **no** (F4: items only for owned playlists) | `canBrowseForeignPlaylists` |
| Artist scope + artist filter | yes | v1: off (later: derive from the local index) | `supportsArtistScope` |
| Date jump | yes | yes | — |
| Hot Preview (30 s clip) | yes | **no** (F6) | `supportsHotPreview` |
| Playback | in-app | via Spotify app, **Premium only**; else none | `playback: .inApp / .companionApp / .none` (Spotify decides at runtime from `canPlayOnDemand`) |
| Album sheet tracklist | yes | yes (`GET /albums/{id}`) | — |
| Editorial notes (album / artist) | yes | no | `supportsEditorialNotes` |
| Artist hub: top songs, similar artists | yes | **no** (F4) → photo + Wikipedia bio + links | `supportsArtistCharts` |
| Insights genre mix | yes | hidden (tracks carry no genres; F11 III.13) | falls out naturally: `genreNames` is empty |
| Share link | music.apple.com | `https://open.spotify.com/track/{id}` | via `Song.externalURL` |
| "Author name" setting | yes | hide | `supportsAuthorName` |

Gate UI with these flags, never with `if provider.id == .spotify`. The existing `playlist.createdByApp` checks (`HomeView.playlistCanRemove`, `ManagePlaylistsSheet` rename swipe, `MusicSwipeViewModel.remoteRemove`, `HistoryStore`/`HistorySheet` movement) all go through one new helper: "can remove from this playlist" = `capabilities.removalRequiresAppCreatedPlaylist ? playlist.createdByApp : playlist.isEditable`.

### C1 — Local library index (the piece that makes Spotify viable)

On Apple Music a "walk the whole library" is a fast local query; the app does it for counts, Unsorted, Insights, History and the Dismissed deck. On Spotify the same walk is 1 network request per 50 songs against a small shared quota (F5). So: **read Liked Songs once, keep them on disk, answer everything from disk.**

`SpotifyLibraryIndex.swift` — an `actor`, persisted as JSON in the caches directory (same debounced-write pattern as `PlaylistTracksCache`):

- Entry: track id, uri, title, artist names, first artist id, album name, album id, image URLs, duration, ISRC, release date, `added_at`.
- `sync()`: `GET /me/tracks?limit=50&offset=0`. If `(total, first id, first added_at)` equals the stored fingerprint → done (1 request). Otherwise re-read every page and replace the index. Also force a full re-read if the last one is older than 24 h.
- Skip items where the track is `null`, `is_local == true`, or `type != "track"`.
- Exposes `isReady` and `lastSyncSucceeded`. **Reconciler rule:** "this ID is not in the index" counts as evidence that a song is gone *only* if the last sync succeeded and the index is non-empty.

Everything the protocol needs is then array work on the index: `libraryPage` (sorted by `added_at`, either direction), `fetchNextLibrarySongs` with exclusions and `startFromDate`, `librarySong(id:)`, `resolveSongs(ids:)`, `libraryAddedDateSpan`. A dismissed song that is not in Liked Songs (the Spotify twin of Apple's "catalog track") resolves with one `GET /tracks/{id}`.

### C2 — Playlists

`SpotifyPlaylistStore.swift`:

- `refreshUserPlaylists()`: page `GET /me/playlists`. `isEditable = owner.id == me.id || collaborative`. `versionToken = snapshot_id`.
- Items: `GET /playlists/{id}/items`, cached per playlist keyed by `snapshot_id` (reuse `PlaylistTracksCache`'s idea; unchanged snapshot → no request). Only for editable playlists.
- `addSong`: check the cached items first — Spotify happily adds duplicates. `POST /playlists/{id}/items` with `{"uris":[uri]}`; store the returned `snapshot_id`.
- `removeSong`: `DELETE /playlists/{id}/items` with `{"items":[{"uri":uri}]}` (removes every copy of that track).
- `createPlaylist`: `POST /me/playlists` (private). `renamePlaylist`: `PUT /playlists/{id}`.
- `fetchAllPlaylistData`: build the membership map from the cached items; refresh only playlists whose snapshot changed, **one at a time**.

### C3 — `SpotifyProvider`

`@MainActor @Observable final class SpotifyProvider: MusicProvider`. Maps DTO → domain (`Song.source = .spotify(uri:)`, `Artwork.remote`), delegates to the index, the playlist store and the API client. `authState` mirrors `SpotifyAuth.state`. `signOut()` clears the Keychain, deletes the index and playlist caches, and **deletes this app's SwiftData rows** (F11 I.1.2: disconnect must delete the user's data). Point `Providers.active` at it under `#if SPOTIFY`.

### C4 — Playback through the Spotify app

`SpotifyPlayback.swift` implements the playback members with App Remote, using what Stage A learned:

- First play of a session wakes Spotify (one app-switch, returns automatically). Afterwards `play(uri)`, `pause`, `resume`, `seek`.
- Player-state callbacks only arrive on changes — run a small timer between callbacks to advance `playbackPosition`.
- `scenePhase` → disconnect on background, reconnect on foreground.
- If `canPlayOnDemand` is false (Free account): `capabilities.playback = .none`; the card shows no play disc, only the open-in-Spotify link.
- No Hot Preview path at all.

### C5 — UI that must differ

- Auth screen: "Connect Spotify" with the official logo file; privacy line must be honest — Culla still stores nothing on a server, but the app now talks to Spotify with your account.
- Card: a visible Spotify attribution + "OPEN SPOTIFY" link (F12). Not full brand compliance — that is Stage D.
- Settings: add **Disconnect Spotify**; hide Hot Preview and author name (flags).
- Source picker: owned/collaborative playlists only; hide the Artists tab (flag).
- User-facing strings that name the service ("Apple Music", "Open in Music", "Apple only lets Culla rename playlists it made", … — 7 keys in `Localizable.xcstrings`) must come from `brand`. English-only is acceptable for the dev edition; translating Spotify strings into the 8 languages is Stage D.
- New error states: not on the allow-list (403), daily quota reached (`QUOTA_EXCEEDED`), login expired (6-month re-auth). Each needs one plain sentence and one button.

### 🧪 Gate 3 — acceptance on device (Spotify edition)

Sign in → Home counts appear → Library deck in add-date order → swipe right into a playlist (check it in the Spotify app) → Undo (it is really removed) → up-swipe creates "Culla Loves" → left-swipe dismiss, appears in Dismissed and History → Unsorted excludes songs already in owned playlists → Move-out works → kill and relaunch (no full re-download: the index is reused) → airplane mode (clear message, no crash) → Disconnect wipes everything.

---

## 7. Stage D — public release (blocked; checklist for the day it unblocks)

Do **not** start this unless Spotify grants extended quota (F3) or the rules change.

1. Company registration, 250k MAU, partner application, extension request, up to 6 weeks of review.
2. One app, two providers: turn `Providers.active` into a runtime choice. Then — and only then — per-provider data separation is needed: a **separate SwiftData store file per provider** (so `PlaylistSyncer`'s "delete local playlists that no longer exist remotely" can never touch the other provider's history), provider-prefixed cache filenames, provider-prefixed `UserDefaults` keys for `lovedPlaylistID`, the queue filters, the count caches and `hasSeededSidebarPlaylists`. Keep today's unprefixed keys for Apple Music so existing users lose nothing.
3. First-run "choose your service" screen; switch/disconnect in Settings.
4. Full brand compliance (F12): a Spotify card variant with nothing drawn over the artwork, 4/8 px corners, no rotation or scaling of the cover, logo + "PLAY ON SPOTIFY", exact metadata. The hero fan, carousel and tile choreography need a compliant variant too.
5. Never show the two services side by side (F11 III.5, F12).
6. Privacy policy on `culla.app/music/#privacy` describing Spotify access; App Store listing, review notes (reviewers need a Spotify test account), 8-language strings, and the "Everything stays on your device" promise re-worded.
7. Re-read the Developer Terms on caching Spotify data before keeping the Stage C index design.

**Not recommended workaround:** "bring your own Client ID" (each user registers their own Spotify developer app and pastes its ID into Culla). Some open-source tools do this, but it needs every user to have Premium and create a developer app, and it stretches "personal, non-commercial" — not something to put in an App Store build without legal advice.

---

## 8. Regression checklist (🧪 Apple Music app, after B3 and B4)

Run on the iPhone with a real library. Anything that behaves differently from the current App Store build is a bug in the refactor.

1. Cold launch: splash → Home; three count badges settle; hero shows covers.
2. Hero: drag to scrub; tap opens the carousel; scroll far (more covers load); date pill jumps; X closes; hero shows the cover you left on.
3. Start from the carousel while a preview plays — music continues into the swipe card.
4. Library session: right-swipe into a sidebar playlist, left (dismiss), up (love), down (share sheet), double-tap (skip). Undo each one.
5. Playback: auto-play on, pause/resume keeps position, scrub the bar, Hot Preview on/off.
6. Card extras: playlist chip → tracklist sheet (tap a row to preview); artist ⓘ → hub (top songs, similar artist push, bio, notes); album ⓘ → liner notes and tracklist (needs *Show album on cards* on).
7. Unsorted session and Dismissed session (un-dismiss by sorting).
8. Sort From: pick one of your playlists, a Culla-made playlist with **Move out**, an Apple-curated playlist (catalog tracks appear, copy only), and an artist.
9. Manage: toggle sidebar playlists, rename a Culla-made playlist, create a playlist, Filter queue for a playlist **and** an artist — the Library deck must rebuild without them.
10. History: rows resolve with covers; swipe to undo a Culla sort and a dismissal; "Open in Music"; greyed rows for deleted songs.
11. Insights: every card fills in; a top-artist row opens the hub.
12. Settings: theme, colour, each toggle, Loved playlist picker.
13. Airplane mode at launch: the app still opens (splash failsafe) and shows last-known data.

---

## 9. Risks

| Risk | Where | Guard |
|---|---|---|
| Refactor breaks the live Apple Music app | B3 | Four small steps, a build after each, §8 on device, optional week in production before Stage C |
| A reconciler runs on "empty because the fetch failed" and greys out real history | B2, C1 | Keep every evidence rule exactly as written; Spotify index only counts as evidence after a successful non-empty sync |
| Spotify symbols leak into the App Store target | A, C | Every Spotify file is `#if SPOTIFY`; build both schemes after every step |
| Dev-mode quota runs out mid-session | C | Local index, snapshot-keyed playlist cache, one request at a time, distinct `QUOTA_EXCEEDED` state |
| Spotify changes the rules again | all | Re-verify §1 before each stage; DTOs decode defensively |
| App Remote is too flaky to "sort by feel" | A4 | That is exactly what Gate 1 measures before anything else is built |
| The user's sorting history is damaged | all | No SwiftData schema change anywhere in this plan; Spotify edition is a separate app with its own store |
