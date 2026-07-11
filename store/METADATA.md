# App Store Connect — Culla Music metadata

Copy-paste sources for the App Store listing. Character limits noted in `[brackets]`.

> **This is an update** (version 1.5.0, build 2) to an app that already exists on the
> Store — bundle `app.culla.music`, App Store ID `6778348600` (live listing:
> `apps.apple.com/us/app/cullamusic/id6778348600`). You're editing the existing record,
> not creating a new one. The listing is **English (U.S.) only** for now.
>
> ⚠️ **Nothing user-facing changed in the code between build 1 and build 2** — this
> release exists to refresh the listing (new screenshots require a new version). The
> What's New text below is written accordingly; if you've shipped anything I can't see,
> add it there.

---

## App information

- **Name** `[30]`: `CullaMusic` *(as on the existing record — the store URL slug is
  `cullamusic`. The name is editable with this version if you ever want e.g.
  `CullaMusic: Sort Your Library` `[29]`.)*
- **Subtitle** `[30]`: `Swipe songs into playlists`
  - *Alt:* `Sort your library by feel`
- **Bundle ID**: `app.culla.music`
- **Primary language**: English (U.S.)
- **Primary category**: **Music**
- **Secondary category**: none (optional: **Utilities**)
- **Copyright**: `© 2026 Alejandro Gómez Urrea`
- **Age rating**: unchanged from v1 — re-confirm the questionnaire (clean utility → **4+**)

## URLs

Live at `culla-web` → `/music/` (auto-deploys to `culla.app` via Netlify). Privacy and
support are in-page anchors, not separate files.

- **Marketing URL** (optional): `https://culla.app/music/`
- **Support URL** (required): `https://culla.app/music/#support`
- **Privacy Policy URL** (required): `https://culla.app/music/#privacy`

---

## Promotional text `[170]`
*(Editable any time without a new review — use it for timely notes.)*

```
Swipe right to file a song into a playlist, left to dismiss it, up to love it. Culla Music makes tidying your Apple Music library fast, tactile, and reversible.
```

## Keywords `[100]`
*(Comma-separated, no spaces. Words already in the name/subtitle — "culla", "music",
"swipe", "songs", "playlists" — are indexed too, so they're intentionally left out.
"apple" pairs with "music" from the name to match "apple music" searches.)*

```
apple,library,organizer,sort,tidy,curate,triage,declutter,mixtape,dj,tracks,album
```

## Description `[4000]`

```
Culla Music is the fastest way to sort your Apple Music library — one song at a time, by feel.

Swipe right to drop the song onto one of your playlists. Swipe left to dismiss it. That's the whole idea: instead of scrolling endless lists, you make one clean decision per song while the music plays — and every decision is written straight to your real Apple Music playlists.

SORTING BY FEEL
• Swipe right toward any playlist in the sidebar to file the song there; swipe left to dismiss it.
• Swipe up to love a song — it lands in a Loved playlist of your choice.
• Swipe down to share the song without losing your place.
• Gentle haptics confirm every decision, and every swipe can be undone.

THREE WAYS TO REVIEW
• Library — your full library, minus everything you've already sorted.
• Unsorted — only the songs that aren't in any of your playlists yet.
• Dismissed — the rejected pile, ready to be rescued or left behind.
• Or point the deck at a single playlist or artist. Audition an Apple-curated playlist and copy the songs you like into your own — including tracks you haven't added to your library yet.

HEAR BEFORE YOU DECIDE
• Each new card starts playing the moment it lands.
• Hot-clip preview jumps straight to the song's best ~30 seconds.
• A scrubbable progress bar with a playhead dot and haptic ticks.
• A fullscreen cover carousel lets you glance ahead through the whole deck and pick where the session starts.
• Jump the deck to a point in time — "everything I added last summer" is one tap away.

KNOW WHAT YOU'RE HOLDING
• Playlist chips show where the current song already lives, so you never re-sort it.
• Album liner notes open Apple Music's editorial notes about the record.
• The artist hub gathers the artist's top songs, similar artists, and a short bio — tap a similar artist to keep digging.

EVERYTHING IS REVERSIBLE
• A full History log of every sort, love, and dismissal — swipe any row to undo it.
• Undo rolls back the playlist change on Apple Music's side too, not just inside the app.

MAKE IT YOURS
• Light, dark, or system theme and a 33-color accent palette.
• A calm Liquid Glass design built for iOS 26, with a clean fallback on earlier iOS.
• Available in 8 languages: English, Spanish, German, French, Italian, Japanese, Brazilian Portuguese, and Simplified Chinese.

PRIVATE BY DESIGN
Culla Music has no server and collects nothing. Your library is read on-device, your choices are stored on-device, and nothing about you leaves your iPhone. No ads, no accounts, no tracking.

Culla Music works best with an active Apple Music subscription (without one, songs play as 30-second previews). Requires access to your Apple Music library. iPhone, iOS 17 or later.
```

## What's New (version 1.5.0) `[4000]`

```
A small housekeeping update:

• A refreshed App Store listing with new screenshots that show today's app.
• Minor under-the-hood tidy-ups — no feature changes this time.

Questions or ideas? Email agomezurrea@gmail.com.
```

---

## App Review Information → Notes
*(Critical — without this the reviewer can't use the app and rejects it as "broken".)*

```
Culla Music requires an active Apple Music subscription to function. Please sign the test device into an Apple ID that has Apple Music and some songs saved in its library, and grant the "Media & Apple Music" permission when the app asks on first launch. The app reads your existing library, then lets you swipe songs right into playlists, left to dismiss, up to love, and down to share.
```

- **Sign-in required?** No login of its own → leave the demo-account fields empty.
- **Contact info**: your name, phone, email.

## Privacy (App Store Connect → App Privacy)

The app makes network calls only to Apple Music (MusicKit) and to public,
auth-free sources for artist bios (Wikipedia / MusicBrainz / Wikidata). Those requests
carry no user identity — no account, no device ID, no analytics — and nothing about the
user is transmitted or retained. Playlist choices live on-device in SwiftData.

- **"Do you collect data?"** → **No** (unchanged from v1)
- Resulting privacy label: **Data Not Collected**
- **Tracking** → **No** (matches `PrivacyInfo.xcprivacy`: `NSPrivacyTracking = false`)
- Matches the published policy at `culla.app/music/#privacy` ("no server of its own,
  does not collect, transmit, or store any personal data").

## Build / version

- **Marketing version**: `1.5.0`  •  **Build**: `2`  (Xcode → target → General)
- **Min iOS**: `17.0`  •  **Devices**: **iPhone only**  •  **Orientation**: Portrait
- **Encryption**: `ITSAppUsesNonExemptEncryption = NO` is set in the build settings, so
  the export-compliance question is auto-answered as exempt (standard HTTPS only).
- **Team**: `56BK7T2JG7` (automatic signing).
- **Price**: Free — no in-app purchases, nothing to attach to the review.
- ⚠️ **Archive from `main`**, never from the `screenshot-neutral-hero` branch — that
  branch has `cullaScreenshotMode = true`, which fakes the sidebar and blocks every
  swipe from writing to the library. A store build from it would be a broken app.
