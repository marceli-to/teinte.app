# Build Teinte — a macOS app to find images by describing them

## The idea

Teinte is a small, calm Mac app. You point it at folders of images. It shows them as a grid or a list, and you filter them by typing a sentence like «show only blue images with people in it». Teinte shows how it understood the sentence (as removable chips like "mostly blue" + "with people"), filters the library and sorts the results by how well they match. A search you like can be saved as a "look" and appears in the sidebar.

Everything runs on the Mac. No account, no backend, and images never leave the machine.

## Platform and stack

- Native macOS app in **SwiftUI**, Apple silicon only. Target **macOS 26** so the on-device Foundation Models framework is available. If that is a problem, tell me before choosing something else.
- Persistence: **SwiftData** (or SQLite via GRDB if you have good reasons; explain them in PLAN.md).
- No third-party UI frameworks. A Core ML model for embeddings is fine (see below).
- Sandboxed, Mac App Store-ready: folder access through `NSOpenPanel` + security-scoped bookmarks, so access survives a restart.

## How it works

### 1. Import (once per image)

When a folder is added, analyse every image once in the background and store the results. Watch the folders, so new, changed or deleted files update the index.

For each image, store:
- **File info:** path/bookmark, name, pixel size, creation date, a cached thumbnail.
- **Colours:** dominant colours with their share of the image. Use k-means (k≈5) on a downscaled copy in a perceptual space (OKLab), then map each cluster to a named bucket: red, orange, yellow, green, teal, blue, purple, pink, brown, black, white, grey. Store the share per bucket, e.g. blue 0.71.
- **People and content (Apple Vision):** number of people (human rectangles), number of faces, classification labels with confidence, and whether the image contains readable text.
- **Embedding:** an image embedding from a CLIP-style model running in Core ML. Start with Apple's MobileCLIP. Check its licence, and find or convert a Core ML version. The same model's text encoder is used at query time.

Analysis must be fast and interruptible: a concurrent queue, progress reporting, resume after quit, and no blocked UI.

### 2. Query (every search)

1. **Parse the sentence into structured filters.** Use the Foundation Models framework with a `@Generable` struct, roughly:
   - `colours: [ColourFilter]` (bucket + mode: `mostly` = share ≥ 0.40, `contains` ≥ 0.10, `without` < 0.05)
   - `people: PeopleFilter?` (any / none / exact count / at least N)
   - `faces`, `text` (with/without), `orientation`, `labels: [String]`
   - `freeText: String?`: whatever is left that the structured fields can't express ("cozy", "sunset over a lake")
2. **Apply hard filters** from the index. They are cheap and exact.
3. **Rank** what's left by cosine similarity between the image embeddings and the text embedding of `freeText` (or of the whole query if nothing structured was found). Show the score as a match percentage.
4. Show each parsed filter as a **chip under the search bar**. Removing a chip re-runs the query without it. The chips are the user's proof that Teinte understood them.

Fallback: if Foundation Models isn't available, use a simple rule-based parser for colours, people and text, plus embedding search for the rest.

Results should update in well under a second for 10,000 images. Precompute the embeddings and hold them in memory as a flat Float array; a brute-force dot product is fine at this size.

## Screens

The mockups are in `design/`. Match them closely, but build real, adaptive SwiftUI layouts, not fixed pixel copies. The image tiles in the mockups are placeholders (colour blocks with figures) for real thumbnails, and all numbers are example data.

- `design/01-grid.png`: **Main window, grid view.** Sidebar with Library (All images, Recently added), Saved looks, Folders. Search bar as the hero element (⌘K focuses it), chips under it, "Save as look" on the right. Result count in large type ("24 of 1,240 images"), then the grid, sorted by match, filename and match % under each tile.
- `design/02-list.png`: **List view.** The same search; columns Image, Colours (top 3 swatches + share of the matched colour), Seen in it (people count + top labels), Size, Match (thin accent bar + %). The list explains *why* each image matched.
- `design/03-first-import.png`: **First import / analysing.** Big counter (812 of 1,240), one calm sentence, progress line (solid accent for done, dashed for still to come), the "library by colour" band (dominant colours of analysed images, sorted by hue), drop zone + "Choose folder…". Also used when a large folder is added later.
- `design/04-app-icon.png`: **App icon.** Two stacked photo prints on the light ground. The front print shows a simple landscape (pale blue sky, terracotta sun, blue and green hills), with that image's three colours as dots in its white bottom border. Produce a proper macOS icon set from it.

Behaviour the mockups don't show but you need:
- Double-click or Space opens a large preview (Quick Look style), with arrow keys to step through results.
- Drag images out of Teinte into Finder or other apps; drag folders into the window to add them.
- Right-click on an image: Show in Finder, Copy, "More like this" (embedding search seeded by that image).
- Empty states: no folders yet (shows the drop zone), no results ("Nothing matches. Try removing a filter.").

## Design

- Colours: ink `#1E2621`, ground `#ECEEE8`, muted text `#47514A`, lines `#D6DAD1`, surface `#FFFFFF`, accent terracotta `#B8502B` (on dark: `#E07A50`). One accent only.
- Type: **Manrope** (600–800 for headings and numbers, 500–600 for text), **JetBrains Mono** for small labels, filenames and figures. Bundle both fonts (both are under the OFL).
- Lots of space; big numbers; small, quiet mono labels in uppercase for section titles.
- Search bar: white, 14 pt radius, 1.5 pt ink border, 56 pt tall.
- Chips: white pills, colour chips get a swatch dot, each has a remove button.
- Light swatches (white, cream) need a hairline ring so they stay visible on the light ground.
- Window: transparent, unified title bar (no visible toolbar background), app name in the title area, view toggle on the right.
- **Dark mode is required.** Derive it from the same palette (ink becomes the ground) and show me screenshots before polishing.
- Every custom control needs hover, pressed and keyboard-focus states, full keyboard navigation, and VoiceOver labels. Images get an accessible description from their labels ("2 people, water, jetty").
- No sparkle icons, no "AI" badges, no chat bubbles. The search bar is a search bar, not a chat.

## How to work

1. Start by writing `PLAN.md`: architecture, data model, analysis pipeline, query pipeline, the `@Generable` filter struct, folder/bookmark handling, and the phases below with acceptance criteria. **Stop and wait for my OK.**
2. **Phase 1 – prototype the core.** Add one folder, run the analysis, and offer a plain search field that shows the parsed filters as text and a basic grid of results. I want to test with my own images whether «blue images with people» actually works before any design work.
3. **Phase 2 – the real app.** The grid and list views as designed, sidebar, chips, saved looks, first-import screen, folder watching.
4. **Phase 3 – Mac polish.** Preview, drag & drop, context menu, "More like this", keyboard shortcuts, dark mode, app icon.
5. **Phase 4 – release prep.** Performance with 10,000+ images, accessibility pass, sandbox and App Store checks, privacy texts.

After each phase: build, run the unit tests, and give me a short summary of what changed and what's next. Tests at least for: colour bucket mapping and shares, filter application (mostly/contains/without, people counts), query parsing for a fixed set of 20 example sentences (write them in PLAN.md), ranking order, and bookmark restore.

## Out of scope for v1 (keep in mind, don't build)

- iCloud sync or a shared library between Macs.
- Photos library integration (folders only for now).
- Editing, tagging by hand or renaming images.
- iOS/iPad version.
