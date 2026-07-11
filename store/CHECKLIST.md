# Culla Music — submission runbook (version 1.5.0, build 2)

This is an **update** to an app that's already live (version 1.0, build 1). You're
uploading a new build and refreshing the existing listing — not creating a new app
record. ✅ = already done in the repo. 👉 = you do it.

## 0. Status

- ✅ Version bumped to `1.5.0`, build `2` (in `project.pbxproj`).
- ✅ Privacy manifest (`CullaMusic/PrivacyInfo.xcprivacy`) — UserDefaults required-reason
  (`CA92.1`), tracking off, nothing collected.
- ✅ `ITSAppUsesNonExemptEncryption = NO` in the build settings — export-compliance
  auto-exempt (standard HTTPS only).
- ✅ iPhone-only, portrait-locked, min iOS 17.0.
- ✅ App localized into 8 languages in-app (listing stays English-only for now).
- ✅ Listing text ready in `store/METADATA.md`.
- ✅ Website live at `culla.app/music/` (the `culla-web` repo) — privacy at `#privacy`,
  support at `#support`.
- ⚠️ **No user-facing code changes since build 1** — this release is a listing refresh
  (screenshots can only change with a new version). What's New is written accordingly.

## 1. Confirm the website is live 👉

URLs already wired into `METADATA.md`:

- **Privacy Policy**: `https://culla.app/music/#privacy`
- **Support**: `https://culla.app/music/#support`  •  **Marketing**: `https://culla.app/music/`

Just confirm they load and both anchors scroll to the right section.

## 2. Screenshots 👉

Follow `store/SCREENSHOTS.md` — **5 shots**, one **iPhone 6.9"** set only (the app is
iPhone-only, so no iPad set). Shoot on your device from the `screenshot-neutral-hero`
branch. Two things to sort out first (both in SCREENSHOTS.md):

- the sample sidebar needs ten `shot_*` images that aren't bundled — add photos or ask
  me to restyle those covers to the neutral glass look;
- capture on your iPhone, and I can resize to the exact store pixels if needed.

## 3. Build & upload 👉 (on your Mac)

1. ⚠️ **Switch to `main` first** — `git checkout main`. The screenshot branch has
   `cullaScreenshotMode = true`, which fakes the sidebar and blocks all library writes;
   a store build from it would be broken.
2. Open `CullaMusic/CullaMusic.xcodeproj`. Confirm version `1.5.0`, build `2` in the
   target's **General** tab. (If build `2` was already uploaded once, bump to `3` —
   every upload needs a higher build number.)
3. Signing team `56BK7T2JG7`, automatic signing.
4. Destination: **Any iOS Device (arm64)**.
5. **Product → Archive**.
6. **Organizer** → select the archive → **Distribute App → App Store Connect → Upload**.
   - The export-compliance question won't appear (handled by the encryption flag).

## 4. Update the listing 👉 (appstoreconnect.apple.com)

1. Open the existing **CullaMusic** app → **(+) Version or Platform** → new iOS version
   **1.5.0**.
2. Paste from `store/METADATA.md`: promotional text, description, keywords, **What's New**.
   (Subtitle lives in App Information — set/confirm it there.)
3. Confirm **Support URL** and **Privacy Policy URL** (step 1).
4. Category **Music**; re-confirm the age-rating questionnaire.
5. **App Privacy**: unchanged — **Data Not Collected**, tracking **No** (see the Privacy
   section in `METADATA.md`; the artist-bio lookups are anonymous public fetches).
6. Upload the **5 iPhone 6.9"** screenshots (replace the old 2).
7. **Build**: select build `2` once it finishes processing (~15 min after upload).
8. **App Review Information → Notes**: paste the Apple Music subscription note from
   `METADATA.md` — without it the reviewer can't use the app and rejects it as broken.
   Fill your contact info.
9. Pricing stays **Free**. No in-app purchases to attach.

## 5. Submit 👉

- **Version Release**: for an update you can also pick **Phased Release** (rolls out
  over 7 days) — with a user base this small, plain **Manually release** or automatic
  is simpler.
- **Add for Review → Submit for Review**. Status flips to **Waiting for Review**;
  approval is usually 24–48 h.

## 6. After approval 👉

- If you chose manual release: open the version → **Release This Version**.
- Check `culla.app/music/` still points at the right listing
  (`apps.apple.com/us/app/cullamusic/id6778348600` — unchanged).
- Optional follow-ups for the next release: localized listings (the app already ships
  8 languages — Spanish first, like Culla), and a real feature-carrying 1.6.

---

### Quick reference
- Bundle ID: `app.culla.music` • Team: `56BK7T2JG7` • Version/build: `1.5.0 (2)`
- App Store ID: `6778348600` (existing record — this is an update)
- Devices: iPhone only • Orientation: Portrait • Min iOS: 17.0
- Category: Music • Price: Free (no IAP)
- Privacy: **Data Not Collected** • Tracking: No
- Listing language: English (U.S.) only, for now
- Screenshots: one 6.9" set, 5 shots (was 2)
