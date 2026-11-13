# Culla Music — new logo, Home redesign, first-run tour

Plan v2, 2026-11-12. Written by Claude Fable 5.2 (v1 was Opus 5.5's) from Alejandro's brief.
**Executed by Claude Opus 5.5 in fresh Claude Code sessions**, with Alejandro testing on his
iPhone between steps. Facts in §2 were checked against the code at commit `a048c19`.

## How to run this plan

- **One part per session:** L, then H, then T. `/clear` between parts. Kickoff prompt:
  `Read docs/LOGO_HOME_TOUR_PLAN.md and continue from the first unchecked step in Status.`
- **After each step:** tick it in *Status* and write any decision he made into the
  *Decisions log* below. That is the only memory that survives `/clear`.
- **Stop only at 🧪 (his device check) and 👉 (his manual step).** Otherwise keep going.
- **Questions:** one `AskUserQuestion` round at the start of a part, recommended option
  first. Don't drip questions one per turn.
- **Save context:** never read the big files whole (`HomeView.swift` 1,239 lines,
  `HomeHeroArtStack.swift` 930). Use the map in §2 and grep the `// MARK` names. Line
  numbers here drift once you edit.

## Status

- [x] L0 questions answered
- [x] L1 workshop → mark chosen
- [x] L2 artwork files + image sets
- [x] L3 mark swapped in the app (build ✅)
- [x] L4 Icon Composer icon saved + checks pass _(done by Claude, see Decisions log)_
- [ ] 🧪 L passed _(deferred 2026-11-13: he will test L, H and T together on device later. Committed untested.)_
- [x] H0 extraction approved and done (build ✅) _(quick 🧪 batched with L's device test)_
- [ ] H1 workshop → layout chosen _(workshop published 2026-11-13, waiting for his line)_
- [ ] H2 layout built (build ✅)
- [ ] 🧪 H passed
- [ ] T0 questions answered
- [ ] T1 tour built (build ✅)
- [ ] T2 strings in 7 languages
- [ ] 🧪 T passed and `replayOnboardingTips` is back to `false`
- [ ] Release prep (§6)

## Decisions log

_(Executor: paste answers and workshop lines here, with the date.)_

- **2026-11-12, L0:** "native composer" = Apple's **Icon Composer**. The mark is
  **Music-only** (not related to the photo app's 3D card-stack icon). The splash and the
  auth screen **keep the words "culla music"** beside the mark.
- **2026-11-12, L1:** workshop published at https://claude.ai/artifact/MANKAP9Madfic7hkhyEKDL
  (v1). A new session updates it by reading that URL first, then publishing with `url`.
  Line format: `mark=… <shape params> accent=#HEX|off bg=#HEX ink=#HEX pad=0.10`; sizes
  are fractions of the 1024 canvas (ring/dot are radii), angles in degrees, 0° = right,
  clockwise. `pad` = empty margin inside the in-app frame (sets the viewBox crop of
  `culla-mark.svg`).
- **2026-11-13, L1 chosen:** `mark=B ring=0.275 stroke=0.145 gap=77 turn=317 sit=0.000
  dot=0.065 caps=round accent=#0A09EF bg=#EEF0F3 ink=#FFFFFF pad=0.10`. Cradle: open
  ring, gap up-right, blue centre dot.
- **2026-11-13, L2:** icon background (set in Icon Composer, not a file) = **#EEF0F3**;
  Dark appearance background = **#18181B** (what the workshop's Dark tile used). Ring
  white, dot #0A09EF. All mark files come from `design/build-mark.py` (edit its numbers
  and re-run to change the mark). The ring spans ~712 px of the 1024 canvas, his workshop
  size, so bigger than the ~640 guess in L2; scale it in Icon Composer if it feels tight.
  **Change from the plan:** in-app uses two image sets, `CullaMarkRing` (template, follows
  `.primary`) and `CullaMarkDot` (original, keeps its blue), stacked in `CullaLogo`. One
  colour image could not flip the ring for dark mode, and a blue dot laid over a
  single-colour mark leaves a dark/white fringe. `design/culla-mark.svg` (one colour) and
  `culla-mark-color.svg` (black ring, blue dot) are the masters for web and store.
- **2026-11-13, L4 (from Apple's guide):** an Icon Composer file **replaces** the AppIcon
  asset catalog, and Xcode builds the older-iOS fallback images from it at build time
  (they look close, not identical). So once `AppIcon.icon` builds, delete
  `Assets.xcassets/AppIcon.appiconset` (it is in git).
- **2026-11-13, L4 done by Claude, at his request:** `AppIcon.icon` was written by hand
  (format copied from VILLE's `AppIcon.icon`) and checked with Icon Composer's `ictool`
  renders of all six looks. Two groups, Dot in front of Ring, each with neutral shadow 0.5
  and translucency **off** (so the white ring stays solid on the light grey). Fill #EEF0F3,
  dark #18181B. The dot has a `tinted` fill of white: without it the dark blue turned
  almost black in Tinted and Clear. `build-mark.py` also writes the two layer SVGs into
  `AppIcon.icon/Assets/`. `AppIcon.appiconset` deleted; the build generates
  `AppIcon60x60@2x.png` etc. for iOS 17 and the pbxproj is untouched. Preview a change
  with: `"$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
  CullaMusic/CullaMusic/AppIcon.icon --export-image --output-file out.png --platform iOS
  --rendition Default --width 256 --height 256 --scale 1` (renditions: Default, Dark,
  TintedLight, TintedDark, ClearLight, ClearDark).
- **2026-11-13, icon ring colour confirmed:** he wants the **white** ring on the light grey
  icon on purpose ("more elegant and distinctive"). Don't swap it to black for contrast.
- **2026-11-13, H0:** split done, build ✅, not committed yet (commit message in §4). He
  chose to **batch the quick 🧪** with the L device test. New layout: `Views/HomeView.swift`
  (566 lines: state, `body`, wordmark, Start CTA, `buildSwipeConfig`, counts),
  `ViewModels/HomeViewModel.swift`, `Views/Home/ModeTile.swift`,
  `Views/Home/ArtistThumbnail.swift`, `Views/Home/HomeView+SourceControls.swift` (Sort From
  card, order / include-dismissed / copy-move rows, plus their read-only helpers). Made
  non-private for the extension: `reduceMotion`, `glassMorph`, `showSourcePicker`,
  `sortOrderRaw`, `sourceTransferModeRaw`, `includeDismissedInScope`, `playlistCanRemove`.
  The §2 line numbers for `HomeView.swift` are now stale; grep the `// MARK` names.
- **2026-11-13, H1 prep:** his screenshots are in `~/Desktop/app store connect/cullamusic/`
  (`IMG_5894.PNG` dark, `IMG_5895.PNG` light: 1170 × 2532 px = 390 × 844 pt, July build,
  Unsorted mode, so no Sort From card). They matched the code's sizes; nothing else needed.
- **2026-11-13, H1 workshop:** https://claude.ai/artifact/LeZaSeCtXuCq21orukAgFq (v1). A new
  session updates it by reading that URL first, then publishing with `url` (the source file
  was in a session scratchpad). It shows Today + A/B/C at real size, light and dark, 6.1″
  and SE, four Home states, with a fit check per phone. **Next step: wait for his line,
  then H2.** Line format and what each value means in SwiftUI:
  `layout=A top=none heroScale=1.08 heroGap=22 heroPos=even tiles=regular dock=off`
  - `layout` A/B/C = the preset he started from (info only; the other values rule).
  - `top`: `none` (no strip; hero rises via the spacer) · `mark` (22 pt `CullaLogo` alone,
    centred in the 38 pt History/Settings row: band = 16 top padding + 38) · `context`
    (one line in that band: bold count + label, e.g. "434 unsorted", "2.397 in your
    library", "86 in <playlist>", "23 by <artist>"; rounded 15 pt medium, secondary).
  - `heroScale`: multiplies `HomeHeroArtStack.size` (168) **and** the resting slot offsets;
    hero frame height = (168 + 24) × scale. Check the carousel morph after changing it.
  - `heroGap`: the `.padding(.bottom, 22)` under the hero.
  - `heroPos`: split of free space between the two spacers. `even` = today (1:1),
    `high` = 1 above : 2 below, `low` = 2 : 1 (do it with extra `Spacer`s, minLength 8 / 12).
  - `tiles`: `regular` = today's `ModeTile` rows · `compact` = one row of three chips
    (icon + count on top, title below, radius 16, padding 10/12, gap 8, no description).
  - `dock`: `on` = Sort From, the scope rows, Order and Start inside one glass panel
    (radius 30, padding 14, gap 12, 10 pt side inset, 8 pt above the bottom safe area).

---

## 0. The brief

1. **New logo.** Redesign the mark "using native composer", read as **Apple's Icon
   Composer** (confirm in L0). Goal: *more unique, subtle and elegant*. Today's mark (a ring
   with five confetti dots) reads "a bit sketchy".
2. **Home redesign.** Remove the "culla music" wordmark strip at the top of Home and rethink
   the page where it helps.
3. **Tour.** A first-run tour like the one in Culla (the photo app): **3 to 5 steps, no more**.

**Order: Logo → Home → Tour.** The tour spotlights real Home controls, so it needs the final
Home layout. What fills Home's top area depends on the new mark.

---

## 1. Rules

Read `AGENTS.md`, `~/.claude/CLAUDE.md` and the memory index first. On top of those:

1. **Build after every step** (no simulator involved):
   ```bash
   xcodebuild -project CullaMusic/CullaMusic.xcodeproj -scheme CullaMusic \
     -configuration Debug -destination 'generic/platform=iOS' \
     CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -20
   ```
   Baseline: `** BUILD SUCCEEDED **`, no warnings in project sources. Keep it that way.
2. **Never run, boot or screenshot the simulator.**
3. **Never ask him to delete the app** to test a fresh install. That wipes his real sorting
   history (SwiftData). Replay first-run UI by flipping `replayOnboardingTips` to `true` in
   `Helpers/DebugFlags.swift` (DEBUG-only; it clears every key in `OnboardingFlags.allKeys`
   at each launch). **Flip it back before any commit.**
4. **Never hand-edit `project.pbxproj`.** `CullaMusic/CullaMusic/` is a file-system-synced
   folder: new files and folders join the target on their own. Asset catalog entries are
   plain folders too, so write them directly.
5. **Deployment target is iOS 17** (the target's setting; the `26.2` in the pbxproj is only
   the project default). Every iOS 26 API needs the existing fallbacks: use
   `Helpers/GlassSurface.swift` instead of raw `.glassEffect`, and honour
   `DebugFlags.forceLegacyUI`. Code ported from the photo app may assume iOS 26. Fix that
   while porting.
6. **Concurrency:** `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, Swift 5 mode,
   `MEMBER_IMPORT_VISIBILITY` on. Each file imports the modules whose members it uses.
7. **Design work = a workshop Artifact first** (CLAUDE.md "Design Workshops"). Load the
   `artifact-design` skill before writing the page. Variants side by side at real size,
   light and dark, with sliders/toggles, ending in **one copyable line** of exact values.
   He pastes the line back; then build. Republish to the same URL on each iteration. If
   two rounds don't settle it, ask what feels off instead of adding more variants.
8. **Logo rule** (CLAUDE.md "NO INLINE LOGO DESIGNS"), applied to our own mark: drawing
   *candidates* as SVG in the workshop is fine, because we are creating the mark. Once he
   picks one, the SVG file in `design/` is the official asset. From then on the app, the
   Home mock-ups, the website and the store all use that file. Nothing redraws it in code.
9. **Scope fence.** Don't touch `Services/`, the swipe screens, or SwiftData models. No new
   dependencies. No refactors beyond H0.
10. **House design rules in memory:** accent halos are heavily restrained; utility screens
    get personality; the swipe card is full-screen (no whole-card geometry transitions);
    swipe pills are flat fills; for motion bugs, get evidence before guessing twice.
11. **Strings:** English is the source. Every new user-facing string goes into
    `CullaMusic/CullaMusic/Localizable.xcstrings` with all **7 translations**: de, es, fr,
    it, ja, pt-BR, zh-Hans. The file has 263 keys: add entries with a small Python script
    (`json.dump(..., ensure_ascii=False, indent=2, separators=(",", " : "))`), then check
    `git diff --stat` shows only added lines. If the whole file changed, the formatting is
    wrong: revert and fix the script.
12. **Commits:** only when he asks; Conventional Commits; straight to `main`.
13. **Talk to him like a beginner,** in a few lines. He flagged verbosity before.

---

## 2. Where things are today (verified)

**Tools.** Xcode 27.2. Icon Composer is installed (Xcode → Open Developer Tool → Icon
Composer). App version 1.5.0 (build 2), bundle `app.culla.music`,
`ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`.

**The mark.** `Helpers/CullaLogo.swift` (66 lines) draws `design/app-icon.svg` with SwiftUI
shapes: a ring and centre dot in `.primary`, plus five fixed dots (#5287D7, #F3F160,
#FE5C55, #78ED6B, #223380). Call sites, all written `CullaLogo()`:

| Where | What |
|---|---|
| `Views/HomeView.swift:777`, inside `wordmark` (`// MARK: - Wordmark`, l.768) | 22 pt mark + "culla" / "music". **The strip he wants gone.** |
| `CullaMusicApp.swift:94`, the splash in `SplashGate` | 92 pt mark + "culla" "music" |
| `Views/AuthGateView.swift:33` | mark + "CullaMusic" |
| `Views/HomeHeroArtStack.swift:379` | mark on a glass tile, the placeholder for a song with no cover |

Text only: "CullaMusic" in `SettingsView.swift:339` (copyright footer). Comments that
mention the old port: `AuthGateView.swift:5`, `HomeHeroArtStack.swift:368`.

**App icon.** `Assets.xcassets/AppIcon.appiconset` holds `AppIcon-Light/Dark/Tinted.png`.
Source art: `design/app-icon.svg` (the only file in `design/`). The catalog also has
`AccentColor`, `apple-music-badge`, `google-g`.

**`Views/HomeView.swift` map** (1,239 lines):

| Lines | What |
|---|---|
| 5–300 | `final class HomeViewModel` (owns the counts) |
| 305 | `struct HomeView` |
| 383 | `body`: a `ZStack` of `HomeAmbientBackground` + one `VStack(spacing: 0)`. **No ScrollView.** |
| ~388 | `wordmark.padding(.top, 22)`, then `Spacer(minLength: 8)` |
| ~393–450 | `HomeHeroArtStack(...)` with the one-time `CoachTip` as a bottom `.overlay` (`showsHeroHint`, `hasSeenHomeHeroHint`) |
| ~468 | `if source == nil { GlassStack { ModeTile … } }`. **The mode tiles disappear once a source is picked.** |
| 797 / 854 | `sourceFilterButton` (the "SORT FROM" card) / `sourceThumbnail` |
| 872 | `orderRow` |
| 913 | `startButton` ("Start Cullaing") |
| 959 / 999 | `includeDismissedRow` / `sourceTransferPicker` |
| 1104 / 1129 | `private struct ArtistThumbnail` / `private struct ModeTile` |

History floats top left and the Settings gear top right. Tapping the hero opens
`HomeArtCarouselView` (`showCarousel`), a morph tied to the hero's position.

**App shell.** `CullaMusicApp.swift`: `SplashGate` shows the splash over `RootView` until
`isReady` flips (0.4 s fade). `DebugFlags.resetOnboardingTipsIfRequested()` runs at l.27.
`Views/RootView.swift` (169 lines) picks `HomeView(… onReady:)` or `AuthGateView`.

**First-run help that already exists.** The tour must not stack on top of it.
- `Views/SwipeGuideOverlay.swift`: one-time guide to the swipe gestures on the first card.
  Flag `OnboardingFlags.swipeGuide` (`"hasSeenSwipeGuide"`).
- The Home hero `CoachTip`. Flag `OnboardingFlags.homeHeroHint` (`"hasSeenHomeHeroHint"`).
- `OnboardingFlags` (with `allKeys`) lives in `Helpers/CoachTip.swift`.

**Culla's tour, the model to port**, in `~/Claude/culla-app/culla/`. All small. Read these
fully before T1, and nothing else from that repo:

| File | Lines | Role |
|---|---|---|
| `Views/TourStep.swift` | 79 | `enum TourStep`: symbol, title, body, button label, anchor, corner radius |
| `Helpers/TourTarget.swift` | ~30 | `TourAnchorsKey` (a `PreferenceKey`) + a modifier built on `anchorPreference(key:value: .bounds)` to tag a control |
| `Views/TourContainer.swift` | 103 | full-screen dim, `.destinationOut` cut-out over the tagged control, pulsing ring, haptic per step |
| `Views/TourCard.swift` | 73 | the card |
| `Views/TourStyle.swift` | 25 | every look/motion number in one `TourStyle.current` line, already tuned by him in a workshop |
| `Helpers/TourEnvironment.swift` | 22 | `activeTourStep` in the environment |
| `CullaApp.swift` l.69–193 only | | hosts it with `.overlayPreferenceValue(TourAnchorsKey.self)`; `@AppStorage` completion flag |

Skip `Views/TourSheetBanner.swift`: it is for steps inside a sheet, and this tour has none.

---

## 3. Part L — Logo

**L0 — One question round** (three questions, recommended first):
1. Does "native composer" mean **Apple's Icon Composer** (layered Liquid Glass app icons)?
   Recommended: yes. If he meant something else, stop and re-plan Part L with him.
2. Should the mark stay related to the photo app's mark, or be Music-only? If related, look
   at the photo app's icon source in `~/Claude/culla-app` before designing.
3. On the splash and auth screen: keep the words "culla music" beside the mark, or show the
   mark alone?

**L1 — Workshop Artifact.** Brief: fewer elements than today, no confetti, subtle, elegant,
one idea, still readable at 22 pt. Five seed directions (starting points, refine freely):
- **A. Disc** — today's ring + centre dot with the confetti gone and the weights retuned.
- **B. Cradle** — an open ring (a "C" with a gap) holding the centre dot: C, record, cradle.
- **C. Sorted** — two offset discs, one staying and one sliding away, like a swiped card.
- **D. Grooves** — two or three partial concentric arcs getting lighter, like record grooves.
- **E. Marker** — a plain ring with one small accent dot sitting on it, like a chosen point.

Show each in real context: Home Screen icon tiles (Default, Dark, Tinted, Clear), the 92 pt
splash, the auth screen, the hero placeholder tile, and a 22 pt size test. Controls: ring
radius, stroke weight, gap angle, dot size, accent on/off and colour, icon background.
The copyable line uses the SVG's own parameter names as fractions of the canvas, e.g.
`mark=B ring=0.34 stroke=0.085 gap=52 dot=0.11 accent=#FE5C55 bg=#0B0B0F`.
Say on the page that the glass look is a CSS approximation; the real glass is tuned in L4.

**L2 — Final artwork.**
- `git mv design/app-icon.svg design/app-icon-v1.svg`.
- `design/icon-layers/1-glyph.svg` (plus `2-accent.svg` if the mark has one): 1024 × 1024
  viewBox, transparent background, **filled shapes only** (turn strokes into filled paths),
  nothing baked in (no gradients, shadows or blur; Icon Composer adds those). Keep the art
  inside the central ~640 px. The background is a colour set in Icon Composer, not a file:
  record its hex in the Decisions log.
- `design/culla-mark.svg`: the single-colour master for in-app use (and
  `culla-mark-color.svg` only if the mark has colour).
- Image set, written by hand at `Assets.xcassets/CullaMark.imageset/`: the SVG plus
  ```json
  {
    "images" : [ { "filename" : "culla-mark.svg", "idiom" : "universal" } ],
    "info" : { "author" : "xcode", "version" : 1 },
    "properties" : {
      "preserves-vector-representation" : true,
      "template-rendering-intent" : "template"
    }
  }
  ```
  A colour version gets its own image set without the `template-rendering-intent` line.

**L3 — Use it in the app.** Do this in the same turn as writing the L4 instructions, so he
can work in Icon Composer while the code is already done.
- Read `CullaLogo.swift` first and keep its exact public API, so the four call sites don't
  change. Replace the shape drawing with the asset `Image` (resizable, scaled to fit).
- Apply L0's answer about the words on the splash and auth screen.
- Fix the two comments that describe the old port.
- Build.

**L4 — 👉 Icon Composer (Alejandro).** Before writing his steps, fetch Apple's guide
"Creating your app icon using Icon Composer" (developer.apple.com/documentation/Xcode) and
use the control names it shows. Don't write the steps from memory. Cover:
1. New icon; drag in the layer SVGs from `design/icon-layers/`.
2. Set the background colour; tune Liquid Glass per layer.
3. Check the Default, Dark, Tinted/Mono and Clear previews.
4. Save as `AppIcon.icon` inside `CullaMusic/CullaMusic/`.

Executor checks afterwards:
- `CullaMusic/CullaMusic/AppIcon.icon/` exists, and `git status` shows no surprise change
  to the pbxproj. If the build log never mentions `AppIcon.icon`, the synced folder missed
  it: give him a 👉 to drag it into Xcode's project navigator.
- Only one icon may be named `AppIcon`. Follow Apple's guide on whether the old
  `AppIcon.appiconset` stays as the older-iOS fallback or goes (v1 of this plan said
  delete; it is in git, so it is recoverable either way).
- Build, then confirm iOS 17 still gets an icon:
  ```bash
  APP=$(xcodebuild -project CullaMusic/CullaMusic.xcodeproj -scheme CullaMusic \
    -configuration Debug -destination 'generic/platform=iOS' -showBuildSettings \
    | awk '/ BUILT_PRODUCTS_DIR = /{d=$3} / WRAPPER_NAME = /{w=$3} END{print d"/"w}')
  ls "$APP" | grep -i icon; plutil -p "$APP/Info.plist" | grep -A8 CFBundleIcons
  ```

🧪 **Device check L:**
- The icon on the Home Screen in light, dark, tinted and clear.
- The splash, and a song without a cover (the hero placeholder).
- The auth screen: turn off Settings → Privacy & Security → Media & Apple Music for the
  app, open it, then turn access back on.

Commit message when he asks: `feat: new brand mark and Icon Composer app icon`.

---

## 4. Part H — Home redesign

**H0 — Extract first** (show this checklist, wait for a yes). No behaviour change:
- `Views/HomeView.swift` → keep `HomeView` with `body` and its state
- `ViewModels/HomeViewModel.swift` → move `HomeViewModel` (l.5–300)
- `Views/Home/ModeTile.swift`, `Views/Home/ArtistThumbnail.swift` → move, drop `private`
- `Views/Home/HomeView+SourceControls.swift` → an `extension HomeView` holding
  `sourceFilterButton`, `sourceThumbnail`, `orderRow`, `includeDismissedRow`,
  `sourceTransferPicker`

The rows read `HomeView`'s private state, and an extension in another file can't see
`private`. Relax `private` only on the members those rows use. Don't turn the rows into
separate views with bindings: that risks behaviour changes. If the compiler then complains
about `HomeView`'s initializer, add an explicit `init` matching today's call in `RootView`.
Build, then a quick 🧪 (Home looks and behaves the same). Commit message:
`refactor: split HomeView into focused files`.

**H1 — Workshop Artifact.** Optional 👉 first: ask him for a light and a dark screenshot of
today's Home from his iPhone, to copy sizes and spacing from. Then 3 layouts at real iPhone
size, light and dark, built from the real elements and the real new mark file:
- **A. Quiet** — strip removed, the hero moves up and grows. Nothing else changes.
- **B. Context line** — one line at the top between History and Settings that says what
  you're about to sort (e.g. "128 unsorted").
- **C. Regrouped** — mode tiles become a compact row under the hero; Sort From and Start
  sit together in a bottom glass dock.

Show each with **and** without a picked source (the tiles vanish when one is picked), and
on a small screen (375 × 667 pt). Copyable line e.g.
`layout=A top=none heroScale=1.08 tiles=regular dock=off`.

**H2 — Build the chosen layout.** All data and state logic stays byte-identical: counts,
hero, carousel, source logic, skeleton loading. Watch for:
- **No ScrollView.** Everything must fit a 375 × 667 pt screen and a large Dynamic Type
  size. See how today's layout copes before changing spacing.
- Removing the strip must not push the hero under the floating History / Settings buttons.
- If the hero moves or resizes, the carousel open/close morph is the likely casualty. If it
  breaks, get a screen recording from him before a second guess (memory rule).
- Keep the hero `CoachTip` for now; Part T removes it.
- Keep the glass vocabulary, accent restraint and Reduce Motion behaviour.

🧪 **Device check H:**
- Cold launch: counts settle and the hero shows covers.
- Scrub and tap the hero; the carousel opens and closes cleanly.
- Each mode, plus Sort From with a playlist and with an artist; the order, dismissed and
  copy/move rows appear when they should.
- Start → swipe card.
- Light and dark, a large Dynamic Type size, and German for truncation.

Commit message: `feat: redesign Home without the wordmark strip`.

---

## 5. Part T — Tour (3–5 steps)

**T0 — One question round:**
1. Are these steps right, or should one go? (Maximum 5.)

   | # | Step | Spotlight |
   |---|---|---|
   | 1 | Welcome: one line on what Culla Music does | none |
   | 2 | "Drag to peek, tap to browse covers" | hero fan |
   | 3 | Library / Unsorted / Dismissed | mode tiles |
   | 4 | Sort from a playlist or an artist | Sort From card |
   | 5 | "Tap Start, then swipe" | Start button |

2. Who sees it? Recommended: **new installs only.**
3. Look: reuse the photo app's tuned `TourStyle.current` values with Music's accent
   (recommended, he already tuned them), or open a new workshop?

**T1 — Build.** `[File] -> [Action]`:
- `Views/Tour/TourStep.swift`, `TourContainer.swift`, `TourCard.swift`, `TourStyle.swift`
  → port from the photo app (§2); new steps and copy
- `Helpers/TourTarget.swift`, `Helpers/TourEnvironment.swift` → port
- `Helpers/CoachTip.swift` → add `OnboardingFlags.tour = "hasSeenTour"` to `allKeys`
- `Views/HomeView.swift` (+ its extension) → tag the four controls; host the overlay;
  remove the hero `CoachTip`

Behaviour, decided here so it isn't re-invented:
- **Host** the overlay with `.overlayPreferenceValue(TourAnchorsKey.self)` on the view that
  contains *all* of Home, floating History/Settings buttons included. Check whether that is
  `HomeView`'s root or `RootView`. It must never cover the swipe screen.
- **Start** once, ~0.6 s after all of these hold: the tour flag is false; the splash is
  gone; the hero has real artwork (reuse the condition `showsHeroHint` uses today); the
  carousel is closed. An empty library gets no tour.
- **Missing target:** if a step's control isn't on screen (the mode tiles when a source is
  picked), skip that step. Never spotlight empty space.
- **While it runs,** the dim layer swallows touches, so Home can't be used underneath.
  Every step has Skip. The last button just closes the tour; it doesn't start sorting.
  Finishing and skipping both set the flag.
- **Step 2 replaces the hero `CoachTip`.** Remove its overlay block, `showsHeroHint`, and
  the `hasSeenHomeHeroHint` writes (one is inside `onHeroTap`). Keep `CoachTip.swift`: it
  hosts `OnboardingFlags`. Delete the old tip's string from the catalog if nothing uses it.
- **Keep `SwipeGuideOverlay`.** The tour hands off to it; step 5 doesn't re-teach swiping.
- **Existing users** (if he chose new installs only): at launch, after the debug reset, if
  `swipeGuide` is already true and `tour` is false, set `tour` to true without showing it.
- **iOS 17–25:** the card uses `GlassSurface`, not raw glass (rule 5).
- **Accessibility:** no ring pulse under Reduce Motion; real `Button`s; the card is modal
  for VoiceOver and takes focus on each step; text wraps at large Dynamic Type.

**T2 — Copy.** Short and plain: a title of a few words and one sentence per step. Add all
7 translations (rule 11).

🧪 **Device check T** (set `replayOnboardingTips = true` first):
- The tour runs once, start to finish, and each spotlight sits exactly on its control.
- Skip works at every step. With a source picked, the mode-tiles step is skipped.
- The swipe guide still appears on the first card.
- Light and dark, and Spanish.
- Then set `replayOnboardingTips = false`, relaunch: no tour.

Commit message: `feat: add first-run tour`.

---

## 6. Release (after all three parts)

- The fixes in commit `88a47c7` (queue filter, voided sorts, up-swipe advance,
  >100 playlists) have **not been tested on device yet**. Test them before or alongside
  this work.
- Ship as **1.6.0** (today: 1.5.0 build 2): new icon, new Home, tour.
- The new icon and Home make the App Store screenshots and What's New outdated. Use the
  `app-store-release` skill and the `store/` folder (memory: shoot from the
  screenshot-neutral hero).
- The website `culla.app/music` (repo `culla-web`) shows the old mark. Update it from
  `design/culla-mark.svg`.
- When each part ships, add a line to the vault project note
  `Projects/Culla-Music/culla-music.md` (`obsidian-vault` skill; the vault auto-commits).
