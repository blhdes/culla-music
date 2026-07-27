# App Store Connect — Culla Music metadata

Copy-paste sources for the App Store listing. Character limits noted in `[brackets]`.

> **This is an update** (version 1.5.0, build 2) to an app that already exists on the
> Store — bundle `app.culla.music`, App Store ID `6778348600` (live listing:
> `apps.apple.com/us/app/cullamusic/id6778348600`). You're editing the existing record,
> not creating a new one. The listing is **English (U.S.) only** for now.
>
> ✅ **1.5.0 is a real feature release** (updated 2026-07-27; this note previously said
> "listing refresh only"). Since build 1: the Insights stats screen, tappable playlist
> chips that open a tracklist sheet, swipe-down share with the arming play disc, History
> tombstones for deleted tracks, a hidden-status-bar Look option, and many fixes. The
> What's New below reflects it.

---

## App information

- **Name** `[30]`: `Culla Music: Swipe Your Songs` `[29]` *(chosen 2026-07-27; the
  record previously showed `CullaMusic` — the store URL slug `cullamusic` stays.)*
- **Subtitle** `[30]`: `Sort your music by feel` `[23]`
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
Swipe right to save a song into a playlist, left to dismiss it, up to love it. Culla Music makes tidying your Apple Music library fast, interactive, tactile and fun.
```

## Keywords `[100]`
*(Comma-separated, no spaces. Words already in the name/subtitle — "culla", "music",
"swipe", "songs", "sort", "feel" — are indexed too, so they're intentionally left out.
"apple" pairs with "music" from the name to match "apple music" searches.)*

```
apple,library,organizer,playlist,curate,triage,declutter,mixtape,dj,tracks,album,tidy,manager,mix
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
• Playlist chips show where the current song already lives — tap one to open that playlist's full tracklist and preview any song.
• Album liner notes open Apple Music's editorial notes about the record.
• The artist hub gathers the artist's top songs, similar artists, and a short bio — tap a similar artist to keep digging.
• Insights turns your sorting history into streaks, top artists, a genre mix, release-decade eras, and a library-coverage gauge — all computed on your iPhone.

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
Culla Music 1.5 is a big one:

• Insights — a new stats screen with your sorting streaks, top artists, genre mix, release-decade eras, and how much of your library you've covered.
• Tap a playlist tag on the swipe card to open that playlist's full tracklist and preview any song.
• The play disc now arms your swipes — drag and it previews what will happen, including the new swipe-down to share.
• History keeps songs you've deleted from your library readable as greyed entries.
• A quieter look: the status bar is hidden by default (Settings → Look), and every settings toggle now explains itself.
• Lots of polish: steadier artwork-tinted colors, smoother card transitions, and Dismissed counts that stay accurate.

Questions or ideas? Email agomezurrea@gmail.com.
```

---

## App Review Information → Notes
*(Critical — without this the reviewer can't use the app and rejects it as "broken".)*

```
Thank you for reviewing Culla Music.

WHAT THE APP DOES
Culla Music is a "swipe to sort" tool for the user's own Apple Music library. You swipe through songs one at a time and file them into playlists: swipe right = add to a playlist, left = dismiss, up = add to a "Loved" playlist, down = share the song.

ACCESS REQUIRED
On first launch the app requests Apple Music access (MusicKit authorization). Please tap "Allow", without it the app has no library to display and the deck will be empty. This is the only permission the app requests. No account creation, sign-in, or demo credentials are needed.

WORKS WITHOUT AN APPLE MUSIC SUBSCRIPTION
The app does NOT require an active Apple Music subscription. If you test on an account without a subscription, playback falls back to Apple's standard 30-second previews and the full swipe / sort / playlist flow still works. Please do not reject under Guideline 2.1 on the basis of "no subscription", the previews are expected, intended behavior, not a defect.

TESTING TIP
For the fullest experience, please test on an account that already has some songs in its Apple Music library and a few playlists, so there is content to swipe through and file.

PRIVACY
The app collects no data and contains no tracking (see the included privacy manifest; the data-collection answer is "Data Not Collected"). Everything stays on device.
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
