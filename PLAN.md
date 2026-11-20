# Teinte — Plan

Status: **approved 2026-11-20.** Phase 1 in progress.

Teinte is a native macOS app. It indexes folders of images on the Mac, and you filter them with a sentence. The sentence is parsed into visible filter chips, hard filters narrow the set, and an image–text embedding ranks what's left.

---

## 0. Decisions to confirm before Phase 1

### 0.1 Embedding model: SigLIP (decided)

MobileCLIP was ruled out. Apple's weights are licensed for research only (`LICENSE_MODELS`: "does not include … use in any commercial product or service").

Teinte uses **SigLIP base patch16-224** (`google/siglip-base-patch16-224`, **Apache 2.0**). It's free, may ship in a paid App Store app, and needs a licence copy and credit in the About window.

- It's converted once with `coremltools` (`script/convert-siglip.py`) into two `.mlpackage`s, an image encoder and a text encoder, with fp16 weights.
- Image input is 224×224, normalised to [-1, 1]. Embeddings have 768 dimensions.
- Text uses a SentencePiece unigram vocabulary of 32k pieces. Text is lowercased and stripped of punctuation, then padded to 64 tokens. The tokenizer is implemented in Swift and checked against golden token IDs from the reference tokenizer.
- SigLIP also ships a learned `logit_scale` and `logit_bias`. These are the starting point for the match-% calibration (§5.3).
- The model sits behind an `EmbeddingModel` protocol, and every stored vector is tagged with a `modelID`. A later model swap means re-embedding in the background.

### 0.2 Platform

- This machine has macOS 26.6 and Xcode 27.2 on Apple silicon. **Deployment target is macOS 26.0** and the build is arm64 only. No problem there.
- Foundation Models needs Apple Intelligence to be enabled and the model downloaded. If either is missing, the rule-based parser takes over automatically (§5.4).
- The project is generated with **XcodeGen** (`project.yml`, already installed here), so the project file stays reviewable and diffable. The `.xcodeproj` is generated and not hand-edited.

### 0.3 Persistence: SwiftData plus a flat embedding file

Metadata, folders, and saved looks go in **SwiftData**. It's first-party, needs no dependency, and covers the needs here: about 10k rows, simple relations, background writes through a `@ModelActor`.

Queries **don't** run against SwiftData. At launch, and after each analysis batch, the store is projected into an in-memory `IndexSnapshot`, which is a struct of arrays (see §5.2). Filtering 10k rows in a tight loop takes microseconds. So SwiftData's predicate limits and its speed never sit on the hot path. That was the main argument for GRDB, and it no longer applies.

Embeddings live **outside** SwiftData in `embeddings.bin`. It's a header plus contiguous `Float16` rows, memory-mapped and loaded once as a `[Float]` matrix. Storing 10k blobs as SwiftData attributes would be slow to load and wasteful.

---

## 1. Architecture

```
TeinteApp (SwiftUI, @main)
├─ UI                      SwiftUI views, design system (Theme, fonts, controls)
├─ AppModel (@Observable, @MainActor)
│   ├─ LibraryState        folders, counts, analysis progress
│   ├─ SearchState         query text, parsed QueryFilters, active chips, results
│   └─ Selection / ViewMode
├─ Library (actor)         folder bookmarks, scanning, FSEvents watching, reconciliation
├─ AnalysisQueue (actor)   bounded concurrent pipeline → AnalysisResult
│   ├─ ThumbnailMaker      ImageIO (CGImageSourceCreateThumbnailAtIndex)
│   ├─ ColourAnalyzer      downscale → OKLab → k-means → buckets
│   ├─ VisionAnalyzer      humans, faces, classification, text presence
│   └─ EmbeddingModel      protocol; SigLIPModel (Core ML)
├─ Store (@ModelActor)     SwiftData writes; emits snapshot deltas
├─ EmbeddingStore          embeddings.bin: append / tombstone / compact / mmap load
├─ Query
│   ├─ QueryParser         protocol; FoundationModelsParser, RuleBasedParser
│   ├─ LabelResolver       maps free words to the Vision taxonomy (+ synonyms)
│   ├─ FilterEngine        hard filters over IndexSnapshot
│   └─ Ranker              vDSP matrix–vector product, top-K, score calibration
└─ Platform                QuickLook panel, drag & drop, NSOpenPanel, Finder reveal
```

The rules:
- Pure logic (colour mapping, filters, rule parser, ranker, calibration) lives in a **`TeinteCore`** local Swift package with no UI imports, so it's unit-testable and fast to build. The app target holds UI and platform glue.
- Swift 6 strict concurrency. Analysis and querying never touch the main actor. The UI gets `AsyncStream` updates.

---

## 2. Data model (SwiftData)

```swift
@Model final class WatchedFolder {
  @Attribute(.unique) var id: UUID
  var displayName: String          // "Shoot Lugano"
  var bookmark: Data               // security-scoped, read-only
  var lastResolvedPath: String     // for display + stale detection
  var addedAt: Date
  @Relationship(deleteRule: .cascade, inverse: \ImageRecord.folder) var images: [ImageRecord]
}

@Model final class ImageRecord {
  @Attribute(.unique) var id: UUID
  var folder: WatchedFolder?
  var relativePath: String         // relative to the folder; file URL = folder URL + path
  var fileName: String
  var fileSize: Int64
  var contentModified: Date        // with fileSize → change detection
  var created: Date
  var addedAt: Date                // "Recently added" = last 7 days
  var pixelWidth: Int
  var pixelHeight: Int

  var status: AnalysisStatus       // .pending / .done / .failed(reason) — resume after quit
  var analysisVersion: Int         // bump to re-analyse after an algorithm change

  // colours
  var bucketShares: [Float]        // 12 values, ordered like ColourBucket.allCases, sum ≈ 1
  var paletteOKLab: [Float]        // k×(L,a,b) cluster centroids, sorted by share (for swatches + colour band)
  var paletteShares: [Float]       // k shares

  // vision
  var personCount: Int
  var faceCount: Int
  var hasText: Bool
  var labels: [String]             // Vision identifiers, confidence ≥ 0.1, top 60
  var labelConfidences: [Float]

  var embeddingSlot: Int?          // row index in embeddings.bin
}

@Model final class SavedLook {
  @Attribute(.unique) var id: UUID
  var name: String                 // defaults to the chip summary, editable
  var query: String                // original sentence
  var filtersJSON: Data            // the QueryFilters *after* chip removals → deterministic, no re-parse
  var createdAt: Date
  var sortIndex: Int
}
```

Thumbnails go in `~/Library/Containers/…/Caches/Thumbnails/<id>.heic`, 512 px on the long edge. They can be regenerated, so they live in Caches.

---

## 3. Folder and bookmark handling

- **Adding:** use `NSOpenPanel` (directories only, multiple selection) or drop folders onto the window. Both give sandbox access. A bookmark is created with `.withSecurityScope` and `.securityScopeAllowOnlyReadAccess`.
- **Entitlements:** `com.apple.security.app-sandbox`, `com.apple.security.files.user-selected.read-only`, `com.apple.security.files.bookmarks.app-scope`. No network entitlement. Fonts and models are bundled, and the app never needs the network.
- **At launch:** resolve every bookmark and call `startAccessingSecurityScopedResource()`. Access is held for the app's lifetime, one call per folder, and balanced at quit.
  - If the bookmark is stale but resolves, recreate it and save it.
  - If it fails to resolve (folder moved to a removed volume or deleted), the folder shows as *unavailable* in the sidebar with a "Locate…" action. Its images stay in the index but are hidden from results.
- **Nested or duplicate folders:** if a new folder is inside an existing one, say so and don't add it twice. If it contains existing folders, merge them.
- **Scanning:** a recursive `FileManager` enumerator that skips hidden files and packages. It keeps UTTypes conforming to `public.image` that ImageIO can decode: JPEG, HEIC, PNG, TIFF, WebP, GIF (first frame), and RAW where ImageIO supports it.
- **Watching:** one `FSEventStream` per folder (file-level events, 1 s latency). Events are coalesced, then reconciled against the index by path, size and mtime:
  - new file → `pending`
  - changed file → reset to `pending`
  - deleted file → remove the record and tombstone its embedding row
  - rename → shows as delete plus add, matched by size and mtime to keep the analysis
- **On launch,** a full reconcile pass catches anything that changed while the app was closed. It compares the folder against the DB and doesn't re-analyse unchanged files.

---

## 4. Analysis pipeline

```
pending records ─▶ TaskGroup (max N = active CPU cores − 2, min 2)
                    per image:
                    1. CGImageSource → detail image ≤ 1536 px, thumbnail 512 px derived from it
                    2. VisionAnalyzer: detail pass (people, faces, text, animals),
                       thumbnail pass (classification, saliency, aesthetics)
                    3. ColourAnalyzer(thumbnail, saliency map)
                    4. EmbeddingModel.embedImage(thumbnail → model input size)
                 ─▶ batched writes (every 50 images or 1 s) → Store + EmbeddingStore
                 ─▶ snapshot delta → UI (progress, colour band, live results)
```

- **Fast:** the source image is decoded once, at ≤ 1536 px, via ImageIO subsampling. Full-resolution RAWs are never decoded. Vision and Core ML run on the Neural Engine and GPU where they can.
- **Interruptible:** the work is `Task`-based with cancellation checks between steps. Pausing cancels the group, and `pending` records stay pending.
- **Resumable:** status is persisted per record. On launch, any `pending` record, or one with `analysisVersion < current`, is queued again. Thumbnails already written are reused.
- **Progress:** done/total counts, an ETA from a moving average of throughput, and the names of the folders currently being analysed. These feed the first-import screen.
- **Priority:** images in visible folders are analysed first. The queue runs at `.utility` priority, so it doesn't starve the UI.
- **Failures** (corrupt file, unsupported codec): the record is marked `failed` with a reason, skipped in results, and counted in the folder's info.

### 4.1 Colours (analysis v3)

1. Downscale to at most 128 px on the long side, **keeping the aspect ratio** (about 12k pixels). Convert sRGB to linear, then to **OKLab**. Ignore fully transparent pixels.
2. **Saliency weighting:** Vision's attention heat map (resampled to 32×32, peak = 1) weights each pixel at 0.3 + 0.7 · saliency, so the subject counts more than the background.
3. **Bucket shares come from the pixels, not the centroids**, with **soft membership**: each colour and its close neighbours (hue ±10°, L ±0.04, chroma ×0.8–1.25, 45 samples) are bucketed, and the colour counts towards each bucket by the fraction that lands there. A colour well inside a bucket stays 100 % there; one on a border (terracotta, dull red brick) counts towards both. Centroids averaged brick and mortar into grey, which is why shares no longer come from them.
4. **Subject and background shares** are stored separately (weights saliency and 1 − saliency). They back filters like "on a white background".
5. **k-means, k = 8** (k-means++ init, at most 12 iterations, fixed seed, saliency-weighted) gives the **palette** only: the list view's swatches and the "library by colour" band.
6. **Look metrics** over all pixels (unweighted): brightness (mean L), contrast (SD of L), saturation (mean chroma), warmth (mean b + ½ a), and the share of pixels with chroma ≥ 0.03 (black and white = < 3 % and mean chroma < 0.012).
7. **Bucket thresholds** use OKLCh (L, C, h). Pure sRGB red sits at h≈29°, orange ≈71°, yellow ≈110°, green ≈143°, teal/cyan ≈195°, blue ≈264°, purple/magenta ≈328°.
   - **Extremes:** L < 0.18 → **black**. L > 0.93 and C < 0.06 → **white** (cream, beige).
   - **Achromatic** (C < 0.02): L < 0.30 → **black**, L ≥ 0.90 → **white**, else **grey**. The threshold is low on purpose: hazy skies (`#B8C9D9`, C≈0.029) must still count as blue.
   - **Chromatic, by hue h in degrees:**

     | h range | bucket |
     |---|---|
     | 345–360 and 0–40 | red; **pink** if L ≥ 0.72 |
     | 40–75 | orange; **brown** if L < 0.65, or if C < 0.08 and L < 0.90 |
     | 75–120 | yellow; **brown** if L < 0.55, or if C < 0.08 and L < 0.85 |
     | 120–175 | green |
     | 175–220 | teal |
     | 220–290 | blue |
     | 290–345 | purple; **pink** if L ≥ 0.70 |

   - The 43 reference colours and their expected (hard) buckets are in `ColourBucketTests`. Terracotta `#B8502B` (h≈39°) is the documented border case: hard bucket red, soft shares red + brown.

### 4.2 Vision (Swift Vision API, two handlers)

| Request | Image | Stored |
|---|---|---|
| `DetectHumanRectanglesRequest` (upper body off) | detail | body boxes (confidence ≥ 0.5) |
| `DetectFaceRectanglesRequest` | detail | `faceCount` (confidence ≥ 0.5) |
| `RecognizeTextRequest` (`.accurate`, language auto, no correction) | detail | `hasText` (a line with confidence ≥ 0.5 and ≥ 3 letters/digits), `recognizedText` (lines ≥ 0.3, ≤ 4000 chars) |
| `RecognizeAnimalsRequest` | detail | "dog"/"cat" labels (≥ 0.5) |
| `ClassifyImageRequest` | thumbnail | labels with confidence ≥ 0.1, at most 60, plus **parent labels** (skyscraper → building, dog → animal) |
| `GenerateAttentionBasedSaliencyImageRequest` | thumbnail | used by the colour analysis (not stored) |
| `CalculateImageAestheticsScoresRequest` | thumbnail | `aesthetics` (−1…1), `isUtility` (screenshots, documents) |

`personCount` = bodies + faces whose centre isn't inside any body. A close-up portrait has a face but no body, someone seen from behind has a body but no face.

Swift Vision gotcha: don't use key paths like `\.boundingBox` on observations. They reference a setter that the macOS 27 SDK has but macOS 26 doesn't, and the app fails to launch (dyld "symbol not found"). Use closures.

### 4.3 Embedding

- The `EmbeddingModel` protocol has `id`, `dimension`, `imageInputSize`, `embedImage(CGImage) -> [Float]`, and `embedText(String) -> [Float]`. Outputs are L2-normalised.
- **Model:** SigLIP base patch16-224 (`SigLIPImage.mlpackage` / `SigLIPText.mlpackage`), 768-dim, see §0.1.
- **Text embeddings** are cached per string (LRU) and use prompt templating ("a photo of {text}").
- **`embeddings.bin`:** a header (magic, modelID, dim, count) followed by `Float16` rows. When loaded it's expanded to a `[Float]` (10k × 768 × 4 B = 31 MB). Deleted rows are tombstoned and compacted at launch when more than 10% are dead.

---

## 5. Query pipeline

```
sentence ─▶ QueryParser ─▶ QueryFilters ─▶ chips (UI)
                              │
                 active chips ▼
          FilterEngine(IndexSnapshot) ─▶ candidate indices
                              │
          Ranker(text embedding, candidates) ─▶ sorted results + match %
```

Each keystroke is debounced by 250 ms. The parse is cancelled if the text changes. The embedding ranking runs on a background task and doesn't block typing.

### 5.1 The `@Generable` filter struct

```swift
import FoundationModels

@Generable
enum ColourBucket: String, CaseIterable, Codable {
  case red, orange, yellow, green, teal, blue, purple, pink, brown, black, white, grey
}

@Generable
enum ColourMode: String, Codable {
  case mostly    // share ≥ 0.40  ("blue images", "mostly blue", bare colour describing the image)
  case contains  // share ≥ 0.10  ("with some red", "teal water", colour of a part)
  case without   // share < 0.05  ("no green", "without red")
}

@Generable
struct ColourFilter: Codable, Hashable {
  @Guide(description: "One of the 12 colour buckets. Map synonyms: navy→blue, crimson→red, beige→brown, gray→grey, turquoise→teal.")
  var bucket: ColourBucket
  @Guide(description: "mostly if the colour describes the whole image, contains if only part of it, without if excluded.")
  var mode: ColourMode
}

@Generable
enum PeopleFilter: Codable, Hashable {
  case any                    // "with people"
  case none                   // "no people", "empty", "without anyone"
  case exactly(count: Int)    // "two people", "a single person"
  case atLeast(count: Int)    // "groups", "at least 3", "crowd" → atLeast(5)
}

@Generable enum Presence: String, Codable { case with, without }
@Generable enum Orientation: String, Codable { case landscape, portrait, square }

@Generable
struct QueryFilters: Codable, Hashable {
  @Guide(description: "Colour constraints. Empty if the sentence names no colour. 'Black and white photo' is NOT a colour filter; put it in freeText.")
  var colours: [ColourFilter]
  @Guide(description: "People constraint, or nil if people aren't mentioned.")
  var people: PeopleFilter?
  @Guide(description: "Visible faces / close-up portraits, or nil.")
  var faces: Presence?
  @Guide(description: "Readable text, signs, screenshots with words, or nil.")
  var text: Presence?
  @Guide(description: "Image shape. 'vertical' = portrait, 'horizontal/wide' = landscape. Not the photographic genre 'portrait'.")
  var orientation: Orientation?
  @Guide(description: "Concrete objects or scenes as single English nouns: dog, beach, car, food.", .maximumCount(5))
  var labels: [String]
  @Guide(description: "What remains that the fields above can't express: moods, styles, scenes ('cozy', 'sunset over a lake'). nil if nothing remains. Never repeat colours or people here.")
  var freeText: String?
}
```

The `LanguageModelSession` gets short instructions plus about 6 few-shot examples taken from §8. Generation uses `respond(to:generating: QueryFilters.self)` at temperature 0. The session is prewarmed at launch.

### 5.2 Hard filters (`FilterEngine`)

`IndexSnapshot` holds contiguous arrays indexed by row: `bucketShares: [Float]` (row × 12), `personCount`, `faceCount`, `hasText`, `orientation` (from the pixel size, square = aspect within ±5%), `labelBits` (a per-row bitset over the label vocabulary seen in the library), `available` (folder reachable), and `embeddingSlot`.

- **mostly:** share ≥ 0.33 (0.40 before analysis v3; per-pixel soft shares spread more). **contains:** share ≥ 0.10. **without:** share < 0.05. Constants live in one place.
- **people:** `any` → ≥ 1, `none` → 0, `exactly(n)` → n, `atLeast(n)` → ≥ n.
- **faces / text:** a boolean test.
- **labels:** each query label goes through `LabelResolver`, which tries an exact Vision identifier, then a synonym table, then a stem or plural match.
  - A label that **resolves** becomes a filter. An image passes if Vision tagged it with the label or a related identifier (`LabelResolver.related`: "building" also accepts apartment, storefront, skyscraper, …), **or** if its SigLIP cosine with "a photo of a <label>" is ≥ 0.055 (`FilterEngine.semanticLabelThreshold`). Vision alone misses too much: red brick facades come back as "structure" / "balcony", not "building".
  - The ranking text is the whole sentence ("a photo of red building"), so a colour stays bound to its object. If the sentence has a negation, or the chips were edited, it's built from the positive parsed parts instead (`RankingPrompt`).
  - A label that **doesn't resolve** is moved into `freeText` for embedding search, so a hard filter never wipes out results by mistake.
  - The chip shows which happened: a solid chip for a hard filter, a lighter chip for a "similar to" filter.

- **Colour region** (analysis v3): a colour filter can target the background ("on a white background") and uses the background shares; images without a saliency map fall back to the whole image.
- **Looks** (measured, `LookFilter`): bright (L ≥ 0.68), dark (L ≤ 0.35), high contrast (SD ≥ 0.27), low contrast (≤ 0.13), vivid (chroma ≥ 0.085), muted (≤ 0.035), warm (≥ 0.035), cool (≤ −0.004), black & white. Thresholds are tuned on the 993-image library; opposites cancel (the later one wins).
- **Styles** (`StyleTag`, judged by SigLIP against a fixed prompt): golden hour, overcast, studio light, film grain, minimal, aerial, macro, night. An image passes when the calibrated match (§5.3, relative to the library) is ≥ 0.5.
- **Text in the image:** every word of `textQuery` must appear in the recognised text (case and diacritics folded). The parser takes quoted text, "saying X", "that says X", "the word X".
- **Screenshots & documents:** Vision's `isUtility`. **Best shots:** aesthetics ≥ 0.3.

Filters combine with AND. The scope comes from the sidebar (All images / Recently added / a folder) and is applied first.

### 5.3 Ranking (`Ranker`)

- **Ranking text** is `freeText` if present, otherwise the whole sentence. When the parse was purely structured ("blue images with people"), the whole sentence still orders the results meaningfully.
- **Scores** are computed with `vDSP_mmul` / `cblas_sgemv` over the candidate rows, which takes under 5 ms for 10k × 768. A partial sort gives the top-K. Everything is shown, but rows render lazily.
- **Structured boost:** when the colour filter is `mostly`, the score adds a small term (`+ 0.1 × share`). Between two equally good matches, the one that's 80% blue then ranks above the one that's 41% blue.
- **Match %:** raw cosines sit in a narrow band (for SigLIP about −0.1 to 0.2), so showing them as-is would read "27%". Calibration:
  1. Compute `p = sigmoid((s − μ) / τ)`, where μ and τ are fitted per model on a calibration set of your images in Phase 1.
  2. Rescale within the result set so the best match isn't shown below its absolute value.

  With no ranking text (for example, only chips are left after removing the rest), results sort by filter strength (colour share, then date), and the % column shows "—".
- **Find similar** (`SimilarityRanking`): `QueryFilters.similarTo` holds the seed (ID + file name), shown as a chip with a thumbnail ("like IMG_2041.jpg"). Three signals, each turned into a z-score over the whole library, then summed: image cosine with the seed (0.65), palette similarity (0.35), and the ranking text when there is one (0.5). Palette similarity is a Gaussian kernel over OKLab distance between palette colours (σ 0.08), weighted by share and normalised like a cosine, so near colours (brick, terracotta) count as close. Match % = sigmoid((z − 2.0) / 0.5) of the combined score against the library. The seed is left out of its own results. Other chips still filter; the seed chip survives re-typing the query and goes with Esc or ×. Tuned on the 993-image library: close matches 90–99 %, the tail 70–80 %.

### 5.4 Fallback parser (`RuleBasedParser`)

This parser is deterministic. It's used when Foundation Models is unavailable, and it's also the reference in tests.

- **Colours:** a lexicon of colour words and synonyms per bucket, so "navy" maps to blue. Mode comes from patterns:
  - "no X", "without X", "not X" → `without`
  - "a bit of X", "some X", "with X", or X before a noun that isn't image/photo/picture → `contains`
  - "mostly X", "X images", or a bare X → `mostly`
  - "black and white" or "b&w" goes to freeText.
- **People:** number words (one through ten, single, couple = 2, pair = 2, group or crowd → atLeast 3/5) combined with person nouns (person/people/man/woman/kid/child/…), plus "no people", "nobody", "empty".
- **Text:** "with text", "screenshots", "signs" → with. "no text", "without text" → without.
- **Orientation:** vertical/portrait-format/tall → portrait, horizontal/wide/landscape-format → landscape, square.
- **Labels:** any remaining nouns that resolve through `LabelResolver`.
- **Free text:** whatever remains after removing matched spans and stop words ("show", "only", "images", "photos", "pictures", "with", "in it", …).

---

## 6. UI (summary; matches `design/`)

- **Window:** `WindowGroup` with `.windowStyle(.hiddenTitleBar)` plus a custom title area. "Teinte" sits next to the traffic lights and the grid/list segmented toggle on the right. On macOS 26 that means the toolbar is transparent (`.toolbarBackgroundVisibility(.hidden)`, with the toolbar items' glass background removed). Minimum size is 900×600.
- **Sidebar:** `NavigationSplitView`, with uppercase mono section labels: LIBRARY (All images, Recently added, with counts), SAVED LOOKS (a dot shows the selected look, accent filled), FOLDERS (unavailable folders are dimmed). The selection drives the scope.
- **Search bar:** a custom control in a translucent, blurred header, soft field tone (#F4F5F0), 12 pt radius, 1 pt ink hairline at 16%, 46 pt tall, with a search glyph and a ⌘K key hint. ⌘K focuses it from anywhere, Esc clears it.
- **Chips row:** "understood as" in mono, then white pill chips. Colour chips have a swatch dot with a hairline ring on light swatches. People chips have a person glyph. Each chip has a × button, which is keyboard-focusable and has a VoiceOver label like "Remove filter: mostly blue". "Save as look" is an accent-outlined button on the right.
- **Header:** the large count ("24") in Geist Light (300), then "of 1,240 images" and a mono hint on the right ("sorted by how well they match" / "why each one matched").
- **Grid:** `LazyVGrid` with adaptive columns (min 220 pt). Tiles have 10 pt rounded corners and keep their aspect ratio within the cell. A mono filename and the match % sit underneath.
- **List:** `Table` with columns Image (thumb plus name), Colours (top 3 swatches plus "71% blue" for the matched bucket, otherwise the top bucket), Seen in it ("2 people · water · jetty"), Size (mono "4032 × 3024"), and Match (thin accent bar plus %).
- **First import:** a big counter, one sentence, a progress line (solid accent up to a dot, dashed after), mono ETA and folder names, the library-by-colour band (up to 40 swatches, hue-sorted), and a drop zone with "Choose folder…". It's shown when the library is empty or a large import (> 200 pending) is running, and it can be dismissed to browse while analysis continues.
- **Empty states:**
  - No folders → the drop zone (a variant of the first-import screen).
  - No results → "Nothing matches. Try removing a filter." with the chips still shown above.
- **Design system:** a `Theme` with light and dark colour tokens, plus Geist and Geist Mono bundled as static cuts of the official OFL variable fonts (sans 300–600, mono 400–500) and registered through `ATSApplicationFontsPath`. Text styles are defined once (`.display`, `.title`, `.body`, `.monoLabel`, …).
- **Dark mode:**
  - ground = ink `#1E2621`, surface = a lifted ink (about `#283029`), text = ground `#ECEEE8`, muted = about `#A9B1A9`, lines = about `#3A443D`, accent = `#E07A50`
  - The search bar border and dark swatches get a light hairline ring.
  - I'll send screenshots of both modes before polishing.

---

## 7. Phases and acceptance criteria

### Phase 1 — Prototype the core
Scope: an XcodeGen project, the `TeinteCore` package, SwiftData store, NSOpenPanel with one folder and its bookmark, the full analysis pipeline (colours, Vision, SigLIP, thumbnails), both parsers, the filter engine, and the ranker. The UI is deliberately plain: a text field, the parsed `QueryFilters` printed as text (plus which parser ran), and a basic grid with filename, match % and a debug overlay (bucket shares, people, labels).

Acceptance:
- [ ] The app builds and runs sandboxed. Adding one folder analyses it with a progress count. The UI stays responsive.
- [ ] After quitting and relaunching, the folder is still accessible (bookmark restore), finished images aren't re-analysed, and unfinished ones resume.
- [ ] «blue images with people» returns colour = mostly blue and people = any, and the grid shows matching images ranked by score.
- [ ] Foundation Models is used when available, and the fallback parser is used (and labelled) when it's not.
- [ ] Unit tests pass: colour buckets, filter application, the rule parser on the 20 sentences, ranking order, and bookmark restore.
- [ ] You test with your own images and we tune the thresholds and calibration together.

### Phase 2 — The real app
Scope: the design system (fonts, colours, controls), the window chrome, the sidebar with all sections, the search bar and chips (remove → re-query), the grid and list views per the mockups, saved looks (save, rename, delete, reorder), the first-import screen with the colour band, empty states, multiple folders, FSEvents watching and the launch reconcile.

Added 2026-11-20 (your requirements, in this order, before FSEvents and look reordering):

1. **Selection and details sidebar.** Click, ⌘-click, ⇧-click, ⌘A, Esc; the selection count in the header. A details panel slides in from the right (⌘I or the toolbar button): a large preview, name, folder path, size, file size, dates, palette with shares, subject vs background colours, looks, style tags, people and faces, labels, recognised text, aesthetics, and the actions Show in Finder and Find similar.
2. **Find similar.** Right-click → "Find similar", or from the details panel. The seed image becomes a chip with a thumbnail ("like IMG_2041.jpg") that combines with other filters. Ranking blends the image embedding (what's in it) with palette distance (its colours). Replaces "More like this" from Phase 3.
3. **Export.** Copy the selected originals, never move them, into one flat folder you choose, or into a zip. Name clashes get a "-2" suffix. The zip is made with `NSFileCoordinator` (`.forUploading`), so there's no dependency. Needs the `files.user-selected.read-write` entitlement; source folders stay read-only by design.
4. **Language.** The UI is localised (String Catalog: English and German, chip titles included). A search-language setting defaults to the system language; non-English queries are translated to English on the device with Apple's Translation framework before parsing and embedding. Quoted text is not translated (it's matched against the recognised text), and Vision text recognition also runs in German. Foundation Models, when available, reads the language directly. A multilingual model (SigLIP 2, v2) could later drop the translation step.
   Built (2026-11-20): Translation needs a one-time language download that only a SwiftUI view can ask for, so there's an offline fallback, `GermanGlossary` (TeinteCore): a word list with adjective endings, compounds and the German names of common Vision labels, which turns a German search into English word by word. Order: Apple Translation if installed, else the glossary. Vision text recognition already auto-detects the language, so no re-analysis. Vision labels show German names from `LabelNames` (~260 most common), English otherwise.

Acceptance:
- [ ] Side-by-side screenshots against `design/01–03` in light mode at the same window size.
- [ ] Removing a chip re-runs the query without it in < 100 ms (the cached text embedding is reused).
- [ ] Adding, changing or deleting a file in a watched folder updates the index and results within about 2 s. Changes made while the app was closed are picked up at launch.
- [ ] A saved look restores the exact chips and results after relaunch.
- [ ] Selecting several images and exporting them to a folder or a zip copies the originals; the details panel shows everything the analysis knows about the selected image.
- [ ] "Find similar" on an image returns visually and chromatically close images first and combines with other chips.
- [x] «blaue Bilder mit Menschen» gives the same chips as «blue images with people», and the UI reads German when the system language is German.

### Phase 3 — Mac polish
Scope:
- Quick Look preview (`QLPreviewPanel` with the result list as its data source; Space or double-click opens it, arrow keys step through results)
- Drag out (file URLs to Finder and other apps)
- Drop folders in
- Context menu (Show in Finder, Copy; Find similar is in Phase 2)
- Keyboard shortcuts:

  | Shortcut | Action |
  |---|---|
  | ⌘K | focus search |
  | ⌘1 / ⌘2 | grid / list |
  | ⌘S | save as look |
  | ⌘O | add folder |
  | ⌘⌫ | remove folder (confirm) |
  | arrows | move through results |

- Dark mode, with screenshots for review first
- The app icon set from `design/04`: two stacked photo prints; the front one shows a landscape (pale blue sky, terracotta sun, blue and green hills) with its three colours as dots in the white bottom border. Redrawn as SVG layers, then a 16–1024 px asset catalog plus the macOS 26 layered `.icon` (back print, front print, artwork as separate layers)

Acceptance:
- [ ] Every action above works with the keyboard alone, and every custom control has hover, pressed and focus states.
- [ ] Dark mode is reviewed by you from screenshots, then polished.
- [ ] Dragging an image into Finder copies the file, and dragging into Mail attaches it.

### Phase 4 — Release prep
Scope: a 10k+ image performance pass, an accessibility pass, sandbox and App Store checks, a privacy manifest and texts.

Acceptance:
- [ ] On a synthetic library of 10,000 images, a query takes < 150 ms end to end after parsing (filter + rank + first render) and < 1 s including the Foundation Models parse. Launch to an interactive library takes < 1 s. Memory measured and documented.
- [ ] Analysis throughput is measured and documented (target ≥ 20 images/s on an M-series chip with SigLIP base).
- [ ] VoiceOver: every image has a description built from its analysis ("2 people, water, jetty"), chips and controls are labelled, and the rotor navigates the results. Contrast is checked in both modes.
- [ ] The About window lists third-party credits (fonts under OFL, SigLIP under Apache 2.0, with the licence text).
- [ ] `PrivacyInfo.xcprivacy`, the App Store privacy label ("Data Not Collected"), and a short privacy text: everything stays on the Mac, no network entitlement.
- [ ] An archive passes validation in Xcode (sandbox, hardened runtime, signing).

After each phase I'll build, run the tests, and send a short summary of what changed and what's next.

---

## 8. Tests (Swift Testing, in `TeinteCore` plus app-level tests where needed)

| Area | What's tested |
|---|---|
| Colour mapping | Reference colours → buckets (navy→blue, terracotta `#B8502B`→orange, `#2E5E4E`→green/teal boundary documented, cream→white, chocolate→brown, salmon→pink/orange documented). Synthetic images: 70% blue + 30% white → blue ≈ 0.70 ± 0.03. Shares sum to 1. k-means is deterministic. |
| Filter application | mostly/contains/without at the boundary values (0.39/0.40, 0.09/0.10, 0.049/0.05). people any/none/exactly/atLeast. faces, text, orientation, labels. AND combination. Scope. |
| Query parsing | The 20 sentences below through `RuleBasedParser`, with the structured fields asserted exactly and freeText checked for presence. The same set runs against `FoundationModelsParser` as an *opt-in* test (it's skipped when the model is unavailable or in CI), and an agreement score is reported. |
| Ranking order | A fake embedding model with hand-built vectors gives the expected order. Ties are broken by colour share. Calibration is monotonic. The no-ranking-text case sorts by filter strength. |
| Bookmark restore | Create a temp folder, bookmark it, reset the in-memory state, resolve the bookmark and read a file. Stale-bookmark refresh. Missing folder → unavailable. |
| Plus | Embedding store round trip, tombstone and compaction. Reconcile diff (add/change/delete/rename). |

### The 20 example sentences

| # | Sentence | Expected |
|---|---|---|
| 1 | show only blue images with people in it | colours [blue mostly] · people any |
| 2 | red photos | colours [red mostly] |
| 3 | pictures with a bit of yellow | colours [yellow contains] |
| 4 | nothing green | colours [green without] |
| 5 | black and white street photos | colours [] · labels [street]* · looks [black & white] |
| 6 | landscape images without people | orientation landscape · people none |
| 7 | exactly two people | people exactly 2 |
| 8 | groups of at least four people | people atLeast 4 |
| 9 | a single person on a jetty | people exactly 1 · freeText contains "jetty" |
| 10 | screenshots with text | text with · utility with (screenshots & documents) |
| 11 | images without any text | text without |
| 12 | close-up faces | faces with · freeText "close-up" |
| 13 | vertical photos of dogs | orientation portrait · labels [dog] |
| 14 | orange and pink sunset over a lake | colours [orange contains, pink contains] · freeText "sunset over a lake" |
| 15 | cozy | freeText "cozy" only |
| 16 | mostly white minimal product shots | colours [white mostly] · styles [minimal] · freeText "product shots" |
| 17 | blue, no people and no text | colours [blue mostly] · people none · text without |
| 18 | warm evening light | looks [warm] · freeText "evening light" (no colour bucket for "warm") |
| 19 | square images of food | orientation square · labels [food] |
| 20 | teal water with one person and a boat | colours [teal contains] · people exactly 1 · labels [boat] · freeText contains "water" |

\* "street" may resolve to a label or fall back to freeText, depending on the Vision taxonomy. The test accepts either, as long as the meaning doesn't get lost.

---

## 9. Repository layout

```
teinte.app/
├─ PLAN.md, prompt.md, design/
├─ project.yml                 XcodeGen spec
├─ Teinte/                     app target (SwiftUI, platform glue, resources)
│   ├─ Resources/Fonts/        Geist, Geist Mono (+ OFL.txt)
│   ├─ Resources/Models/       *.mlpackage (gitignored if > 100 MB; fetched by script/fetch-models.sh)
│   └─ Teinte.entitlements
├─ Packages/TeinteCore/        pure logic + tests
├─ TeinteTests/                app-level tests (bookmarks, store)
└─ script/                     fetch-models.sh, gen-icon.sh, make-test-library.sh
```

The folder isn't a git repository yet. I'd run `git init` at the start of Phase 1 so each phase is a reviewable commit.

---

## 10. Out of scope for v1

iCloud sync or a shared library, Photos library integration, editing/tagging/renaming, iOS/iPadOS.

**Planned for v2:** a stronger embedding model, SigLIP 2 or SigLIP so400m at 384 px (Apache 2.0). Embed without stretching to a square, plus a few crop embeddings per image, and compare on a real library before switching. A model change means re-embedding the library (`EmbeddingStore` resets on a new model ID) and retuning `MatchCalibration.generic` and `FilterEngine.semanticLabelThreshold`.
