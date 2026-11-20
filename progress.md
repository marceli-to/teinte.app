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

## Phase 2 — The real app ⏳ waiting for your feedback on Phase 1
## Phase 3 — Mac polish
## Phase 4 — Release prep
