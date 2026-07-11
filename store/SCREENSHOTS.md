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

Shoot from the **`screenshot-neutral-hero`** branch — it has `cullaScreenshotMode = true`
(top of `Views/PlaylistSidebarView.swift`) baked in. In this mode:

- the Home hero fan shows **neutral Liquid-Glass covers** with a music-note glyph
  (no real album art in the hero);
- the right-drag **sidebar** shows dressed-up sample playlists (genre names) instead of
  your live playlists;
- the swipe deck is **guarded** — no release can dismiss / love / assign / share, so you
  can frame the drag freely and never lose a song.

⚠️ **Missing assets**: the sample sidebar rows reference ten cover images named
`shot_drive`, `shot_festival`, `shot_golden`, `shot_jazz`, `shot_heartbreak`,
`shot_focus`, `shot_gym`, `shot_roadtrip`, `shot_coffee`, `shot_friday` — they are
**not bundled** (dropped in `c6a0136`). Before shooting the swipe shot, drop ten
square-ish photos with those names into `Assets.xcassets`, or ask me to restyle the
sidebar covers to the same neutral glass-glyph look as the hero so no photos are needed.

⚠️ The swipe card and the fullscreen carousel still show **real album artwork** (only
the hero fan is neutralized). That's fine for the App Store — screenshots must show the
actual app — but say the word if you'd rather neutralize those too.

Build to your device from this branch, shoot, and archive the store build from `main`.

## How to capture (on your device — no Simulator)

1. Open Culla Music, set up the shot (mode, drag state, sheet).
2. Press **Side button + Volume Up** together → it lands in Photos.
3. AirDrop / sync to your Mac.

## The 5-shot list

1. **Hero — Home** — the mode picker with the hero fan of glass covers, ambient glow
   behind. First impression of the whole idea. Your most important shot.
2. **The swipe** — a card mid-drag to the right, sidebar open, one playlist row
   highlighted as the drop target, membership chips visible. The core gesture.
3. **Fullscreen carousel** — the cover carousel with a centred cover playing; shows
   how you glance ahead and pick a starting song.
4. **Artist hub** — the artist sheet: top songs, similar artists, the About bio.
5. **History** — the History sheet with a few sorted / loved / dismissed rows (one
   mid-swipe showing the undo action, if you can frame it).

*(Optional 6th: Settings with the accent palette open — "make it yours".)*

## Caption copy (overlay text) — optional

One idea per screen, 2–4 words, English only for now:

1. Home → **Your library, by feel.**
2. Swipe → **Swipe right to playlist.**
3. Carousel → **Glance ahead.**
4. Artist hub → **Meet the artist.**
5. History → **Undo anything.**
6. (Settings → **Make it yours.**)

### Design notes
- Same size, weight, and y-position on every shot — reads as one family.
- Raw screenshots with no captions are perfectly acceptable too; the first 3 shots are
  what shows in search results, so put Home / Swipe / Carousel first.
