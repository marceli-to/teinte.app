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

**Your turn:** look at the app (or `design/review/`) and tell me what to change. Then: analysis refinement (match %, labels), followed by FSEvents watching + launch reconcile and drag-to-reorder looks.

## Phase 3 — Mac polish
## Phase 4 — Release prep
