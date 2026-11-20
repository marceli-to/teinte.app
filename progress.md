# Teinte — Progress

Short status log. Details live in `PLAN.md` (spec) and git history (changes).

## Phase 1 — Core prototype ✅ (2026-11-20)

- Embedding model: SigLIP base patch16-224 (Apache 2.0) converted to Core ML; parity vs PyTorch ≥ 0.9995. Models are gitignored (~405 MB); rebuild with `script/convert-siglip.py`.
- `TeinteCore` package: colour buckets (OKLab + k-means), filters, chips, rule-based parser, ranker, embedding store, bookmarks, SigLIP tokenizer.
- App: add folders (⌘O / drop), background analysis (resumable), search field, parsed filters as text, removable chips, grid with debug overlay (colours, people, labels, cosine).
- Tests: 34 core + 3 app tests pass. The 20 example sentences pass with the rule parser.
- Open:
  - Foundation Models is untested because Apple Intelligence is off on this Mac. Until it's on, the app uses the rule parser.
  - The match % calibration is SigLIP's raw sigmoid, which may show low numbers. We'll tune it on your images.

**Your turn:** run the app, add a folder of your own images, and try «blue images with people». Turn the Debug checkbox on to see why each image matched.

## Phase 2 — The real app ⏳ in progress

Your Phase 1 feedback: it works well. The analysis needs refinement, but the design comes first.

### Step 1 — Design ✅ (2026-11-20)

- Design system: `Theme` (light and dark tokens), Manrope (500–800, static cuts from the OFL variable font) and JetBrains Mono bundled under `Resources/Fonts`, with both OFL texts.
- Window: transparent title bar with "Teinte" and the grid/list toggle, a line under it, and the sidebar you can hide (⌃⌘S).
- Sidebar: LIBRARY (All images, Recently added = last 7 days, with counts), SAVED LOOKS, FOLDERS (unavailable folders dimmed, right-click for Show in Finder / Remove), and "Add folder…".
- Search bar per spec (⌘K focuses it, Esc clears it), the "understood as" chips (remove → re-query), and "Save as look" (⌘S) with a name prompt.
- Saved looks are stored in SwiftData with the exact filters. Selecting one restores them without re-parsing. Right-click to rename, move up/down or delete.
- Grid (4:3 tiles, mono filename + %) and list (Image, Colours with the top 3 swatches + share of the matched colour, Seen in it, Size, Match bar). Empty states.
- Import screen: big counter, progress line, ETA, folder names, library-by-colour band, drop zone. Shown with no folders, during the first import, and during large imports (> 200 left), with "Browse while it works".
- The Phase 1 debug info is now under View › Show Analysis Details (⌥⌘D).
- Screenshots (light and dark) in `design/review/`. They come from a debug-only in-app renderer (`TEINTE_SNAPSHOT=1`), because the shell has no screen-recording permission. That renderer draws pill ends slightly flat ("Save as look", "Choose folder…"); the real window should be fine, so please check it.
- Deviations from the mockups:
  - Grid tiles crop to fill a 4:3 cell, as in the mockup, instead of letterboxing. Letterboxing left big uneven gaps with real photos.
  - The list is a custom view, not `Table`, so it can match the mockup's type and spacing.
- Known: the match % shows 0% for most results. That's the SigLIP calibration, part of the analysis refinement.

### Step 1b — Design feedback ✅ (2026-11-20)

- No more glaring white: the search bar, chips and toggle use a soft `field` tone (#F4F5F0). Selected and hovered rows use a light ink tint (`selection`, ink at 7.5%), darker than the ground.
- Search bar border: a 1 pt ink hairline at 16%, 26% on hover, and 1.5 pt at 38% when focused (was 1.5 pt solid ink).
- The search header (search bar + chips) is translucent: the results scroll under it and are blurred (thin material + 62% ground). New `*-scrolled.png` screenshots are in `design/review/`. The offscreen renderer doesn't draw the blur, so check it in the app.

### Step 1c — Geist and the lighter type ✅ (2026-11-20)

- Manrope and JetBrains Mono are replaced by Geist (500–800) and Geist Mono (400–600). Both are OFL, from Google Fonts, cut to static weights. Sizes are unchanged. `Font.manrope` is now `Font.sans`.
- Screenshots are in `design/review/geist/`. The Manrope ones are still in `design/review/` for comparison.
- Lighter set: body text 400, chips/search/list filenames 500, title/headings 600, big numbers 300 (Light), "of 993" 400. Mono 400/500. Bundled cuts: Geist 300/400/500/600, Geist Mono 400/500. Screenshots are in `design/review/geist-light/`.
- Smaller: sidebar items 13 pt (rows 32 pt, counts mono 11), "of N images" 14 pt, header hint ("newest first" / "sorted by …") mono 11.
- List rows: filename 13 pt, seen-in-it 13 pt, mono figures 12, swatches 18 pt, thumbs 56×42, rows 60 pt. Search bar: 46 pt tall, 12 pt radius, text 16, placeholder 14, centred in the header with equal top/bottom padding.
- Geist and Geist Mono are kept. PLAN.md and the README are updated.

### Step 2a — Label search fix ("red building") ✅ (2026-11-20)

- Cause: "building" was a hard Vision filter, and Vision rarely says "building" with confidence. Red brick facades (`picsum_437`, `_819`, `_859`) came back as "structure", "balcony", "door", "apartment". The red share was fine.
- Labels now pass on Vision (the label or a related one, e.g. building ← apartment, storefront, skyscraper) **or** on SigLIP ("a photo of a building" cosine ≥ 0.055, tuned on your library).
- Ranking uses the whole sentence ("a photo of red building"), so the colour stays on the object. It falls back to the parsed parts when there's a negation.
- Analysis v2 keeps Vision labels down to 0.1 confidence (was 0.3, top 20). **Your library re-analyses once on next launch.**
- Simulated on your library: "red building" goes from 6 results (mostly sunset skylines) to 14, with the three red buildings on top.
- Tests: 39 core + 4 app pass.

### Step 2b.1 — Match % ✅ (2026-11-20)

- The match % is now two checks multiplied: **relative** (how far the image stands out from the whole library for the same query, as a z-score) and **absolute** (a floor on the raw cosine, so a query with no real match stays low). Search-side only, no re-analysis.
- Simulated on your library (top 10):
  - "red building": 98 94 91 90 89 89 86 73 59 53
  - "a dog": 96 95 94 88 86 76 66 58 49 40
  - "golden hour beach": 88 81 78 … 71
  - "blue images with people": 64 53 50 … 13
  - "a unicorn" (none in the library): 35 27 27 … 12
- Tuned for SigLIP base (`MatchCalibration.generic`); retune if step 5 switches model. Libraries under 30 images use the absolute check only.
- Tests: 41 core + 4 app pass.

### Step 2b.2–4 — Looks, colour, Vision ✅ (2026-11-20)

Analysis v3. Your library was re-analysed once (993 images, about 6 minutes).

- **Looks (measured):** brightness, contrast, saturation, warmth, black and white. New chips: bright, dark, high/low contrast, vivid, muted, warm, cool, black & white. Thresholds are tuned so each picks about 10–15 % of your library: bright 176, dark 101, high contrast 86, low contrast 104, vivid 103, muted 156, warm 125, cool 127, b&w 100.
- **Style tags (SigLIP, judged against the library like the match %):** golden hour 20, overcast 24, film grain 13, minimal 20, aerial 18, macro 37, night 46, studio light 0 (your library has no studio shots). The picks were checked on contact sheets and look right, except film grain, which leans towards faded vintage looks.
- **Colour:**
  - Shares now come from the pixels (128 px, aspect kept), not the cluster centres.
  - Vision saliency weights the subject (background pixels count 0.3).
  - Border colours count towards both buckets: terracotta and brick are now red + brown, not all brown. Images that were "mostly brown" went from 225 to 165.
  - The palette uses 8 clusters.
  - Subject and background colours are stored separately: "product on a white background" is a new filter.
  - Shares spread more, so "mostly" is now ≥ 33 % (was 40 %), which keeps the counts about the same.
- **Vision:**
  - People, faces and text run at 1536 px. People = bodies + faces without a body.
  - Recognised text is stored and searchable: quotes, "saying X", "the word X". Images with text went from 36 to 95.
  - Animals (dog, cat) and parent labels (skyscraper → building, dog → animal) are added.
  - Each image gets an aesthetics score: "best shots" (≥ 0.7) picks 269 images.
  - "Screenshots & documents" needs Vision's utility flag **and** a low aesthetics score, because Vision also flags well-shot flat-lays. Your library has no screenshots, so this filter is untested on real ones.
  - People counts barely changed (93 → 95 images with people, faces 19 → 20).
- The rule parser and the Foundation Models schema know all the new filters. Three of the 20 example sentences changed meaning ("black and white" and "warm" are now looks, "minimal" is now a style). PLAN.md §4, §5.2 and §8 are updated.
- Fix along the way: Swift Vision key paths (`\.boundingBox`) crash the app at launch on macOS 26 when it's built with the 27 SDK. They're replaced with closures, and the gotcha is noted in PLAN.md.
- Tests: 54 core + 4 app pass.

Your feedback: "it works perfectly."

### Step 2b — Analysis refinement ✅ (steps 1–4; step 5 moved to v2)

Agreed order. Steps 2–5 need a re-analysis: bump `currentAnalysisVersion` once at the end, not per step. Longer imports are fine.

1. ~~**Match %.**~~ Done (2b.1). Replace SigLIP's raw sigmoid (shows ~0%) with a relative calibration: how a result compares with the rest of the library for the same query. Search-side only.
2. ~~**Look descriptors.**~~ Done (2b.2–4). Per image: brightness, contrast, saturation, warm/cool, a black-and-white flag, and zero-shot style/light tags from fixed SigLIP prompts ("golden hour", "overcast", "studio light", "film grain", "minimal", "aerial", "macro", "night"). New filters/chips.
3. ~~**Colour.**~~ Done.
   - Weight the subject over the background using Vision saliency, and store subject vs background colours.
   - Use about 8 clusters at more than 64×64 (the image is currently squashed).
   - Let a colour count partly towards two neighbouring buckets; red brick currently lands in brown.
4. ~~**Vision.**~~ Done.
   - Run people/face detection at about 1024–1536 px instead of the 512 thumbnail, and pair faces with bodies for counts.
   - Store the recognised text so it's searchable, and add parent labels.
   - Add animal recognition and the aesthetics score, which also flags screenshots and documents.
5. ~~**Stronger embedding model (separate test).**~~ Moved to v2 (2026-11-20), see PLAN.md §10. SigLIP 2 or SigLIP so400m at 384 px (Apache 2.0). No stretching to a square, plus a few crop embeddings per image. Compare on this library before switching.

Tip: `/tmp/teinte-probe` had a CLI probe (SigLIP + `embeddings.bin`) used to tune thresholds. It's outside the repo; rebuild if needed.

### Where we are (2026-11-20, end of session)

- Everything is committed on `main`. The app builds, and all tests pass (54 core + 4 app). Your library is on analysis v3.
- Handy tools outside the repo (rebuild if `/tmp` was cleared):
  - `/tmp/teinte-probe/probe "<text>"`: SigLIP cosines over `embeddings.bin`.
  - `/tmp/teinte-colour/colour <file>`: colour analysis of one image.
  - `/tmp/teinte-sheet/stats.py`: decodes the SwiftData store and prints look/aesthetics distributions.
  - `/tmp/teinte-sheet/sheet`: contact sheets.
- Backup of the v2-analysed store: `/tmp/teinte-backup-v2`.

### Step 3 — Your new requirements (agreed 2026-11-20)

Details in PLAN.md §7, Phase 2. Your answers: UI and search both in German; similar = content and colour; export = copy, flat, originals; order as below.

1. Selection + details sidebar ✅
   - Click selects, ⌘-click toggles, ⇧-click selects a range, ⌘A selects all results, Esc or ⇧⌘A deselects, and the arrow keys move (⇧ extends). The header shows "N selected · Deselect". In the grid, unselected tiles fade to 35 % while there is a selection; selected list rows get a tint.
   - ⌘C copies the selected files, as in Finder (inside the search field it still copies text). The context menu has Show Details, Show in Finder and Copy, and acts on the whole selection.
   - Details panel on the right (⌘I, the toolbar button, a double-click, or Show Details): a 900 px preview of the original, name and folder, size, file size, EXIF (taken, camera, settings) when present, the palette strip, top colours with shares, subject vs background, looks and style tags, brightness/contrast/saturation/quality meters, people, faces and labels (hover shows Vision's confidence), and recognised text. With several images selected, it shows their thumbnails, shared colours, Show in Finder and Copy.
   - Screenshots are in `design/review/details/`.
   - Double-click now opens the details instead of revealing in Finder.
2. Find similar ✅
   - Right-click → Find Similar, or "Find similar" in the details panel. The image becomes a chip with its thumbnail ("like picsum_437.jpg") and combines with other chips: "with people" keeps only the similar images with people.
   - Ranking blends what's in the image (SigLIP image-to-image cosine, weight 0.65) with its colours (palette distance in OKLab, 0.35), plus the typed text if there is one. Each part is compared with the whole library first, so they add up on the same scale. The seed itself is left out.
   - The chip stays when you type a new query; × or Esc removes it. Saved looks keep it.
   - Checked on contact sheets of 6 seeds: the blend keeps the content and prefers the same colours (warm streets for a red-brick street, bright food for a bright bowl). Match %: close matches 90–99 %, the tail 70–80 %.
   - Screenshots are in `design/review/similar/`.
   - Tests: 61 core + 4 app pass.
3. Export (folder or zip)
4. Language (German UI + search)

Then the rest of Phase 2: FSEvents folder watching with a launch reconcile, and drag-to-reorder for saved looks.

## Phase 3 — Mac polish
## Phase 4 — Release prep
