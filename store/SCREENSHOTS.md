# App Store screenshots — Culla Music

Culla Music is **iPhone-only** (`TARGETED_DEVICE_FAMILY = 1`), so App Store Connect
needs just **one** screenshot set. The live listing has 2 shots — this release ups
that to **5** (limit is 10).

## Required size (portrait)

**iPhone — 6.9" slot** (one of):
- **1320 × 2868** (iPhone 16 Pro Max), or
- **1290 × 2796** (iPhone 15/16 Pro Max) — either is accepted.

A single 6.9" set covers all smaller iPhones. No iPad set — the app doesn't target iPad.

> Don't have a 6.9" iPhone? Capture on whatever you have and resize to the exact pixels
> above — tell me your shots' sizes and I'll resize them for you.

## Screenshot mode (before you shoot)

**Why this exists**: Apple rejected earlier screenshots that showed real album artwork
(**Guideline 5.2.1 — Intellectual Property**). Every shot must avoid third-party album
art, artist photos, and editorial covers. That's what `cullaScreenshotMode` is for.

Shoot from the **`screenshot-neutral-hero`** branch — it has `cullaScreenshotMode = true`
(top of `Views/PlaylistSidebarView.swift`) baked in. In this mode:

- the Home hero fan shows **neutral Liquid-Glass covers carrying the Culla brand mark**
  (full-colour up front, smaller and faded behind — no real album art);
- tapping the hero is suppressed (the fullscreen carousel would show real covers);
- the right-drag **sidebar** shows dressed-up sample playlists (genre names) instead of
  your live playlists;
- the swipe deck is **guarded** — no release can dismiss / love / assign / share, so you
  can frame the drag freely and never lose a song.

⚠️ **Missing assets**: the sample sidebar rows reference ten cover images named
`shot_drive`, `shot_festival`, `shot_golden`, `shot_jazz`, `shot_heartbreak`,
`shot_focus`, `shot_gym`, `shot_roadtrip`, `shot_coffee`, `shot_friday` — they are
**not bundled** (dropped in `c6a0136`). Before shooting the swipe shot, drop ten
square-ish photos with those names (your own photos, not album covers) into
`Assets.xcassets`, or ask me to restyle the sidebar covers to the brand-mark glass
look so no photos are needed.

⚠️ **Still showing real artwork** (screenshot mode does NOT neutralize these yet): the
swipe card's cover, the History sheet's row thumbnails, the artist hub, and the album
liner-notes sheet. Shots of those surfaces risk another 5.2.1 rejection until they get
the same neutral treatment — ask me to extend the mode before shooting them.

Build to your device from this branch, shoot, and archive the store build from `main`.

## How to capture (on your device — no Simulator)

1. Open Culla Music, set up the shot (mode, drag state, sheet).
2. Press **Side button + Volume Up** together → it lands in Photos.
3. AirDrop / sync to your Mac.

## The 5-shot list (rights-safe)

Chosen to tell five different stories without third-party artwork. ✅ = capturable
today; 🔧 = needs screenshot mode extended first (small code changes, on request).

1. **Hero — Home** ✅ — the mode picker with the brand-mark hero fan, ambient glow
   behind. First impression of the whole idea. Your most important shot.
2. **The swipe** 🔧 — a card mid-drag to the right, sidebar open, one playlist row
   highlighted as the drop target, membership chips visible. The core gesture.
   *Needs: neutral swipe-card cover + the `shot_*` sidebar images.*
3. **Swipe up to love** 🔧 — the same card pulled upward toward the Loved drop.
   Second gesture story, nearly free once shot 2 works.
4. **History** 🔧 — the History sheet with a few sorted / loved / dismissed rows (one
   mid-swipe showing the undo action, if you can frame it).
   *Needs: neutral row thumbnails.*
5. **Settings** ✅ — the accent palette / theme cards open — the "make it yours" shot.

*(The fullscreen carousel and the artist hub photograph beautifully but are built
around real covers and artist photos — skip them until/unless we neutralize those
surfaces too.)*

## Caption copy (overlay text) — optional

One idea per screen, 2–4 words, English only for now:

1. Home → **Your library, by feel.**
2. Swipe → **Swipe right to playlist.**
3. Love → **Swipe up to love.**
4. History → **Undo anything.**
5. Settings → **Make it yours.**

### Design notes
- Same size, weight, and y-position on every shot — reads as one family.
- Raw screenshots with no captions are perfectly acceptable too; the first 3 shots are
  what shows in search results, so put Home / Swipe / Carousel first.
