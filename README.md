# Teinte

A macOS app that finds images by description. Everything runs on the Mac. See `PLAN.md` for the architecture and phases.

## Build

Requirements: macOS 26, Xcode 27, XcodeGen (`brew install xcodegen`).

```sh
# 1. Embedding model (one time, about 10 min, needs ~3 GB of downloads for PyTorch).
#    Writes Teinte/Resources/Models/SigLIP*.mlpackage (gitignored, ~405 MB), vocab and metadata.
#    Needs an arm64 Python 3.12; the exact setup commands (via uv in .tools/) are at the top of
#    script/requirements-convert.txt.
.tools/venv/bin/python script/convert-siglip.py

# 2. Project + app
xcodegen generate
open Teinte.xcodeproj        # or: xcodebuild -scheme Teinte build
```

Without step 1 the app still runs, but without embedding ranking. The status line says so.

## Tests

```sh
cd Packages/TeinteCore && swift test     # colours, filters, parser (20 sentences), ranking, tokenizer, bookmarks, store
xcodebuild -scheme Teinte test           # Core ML parity, Vision pipeline, Foundation Models parser (needs Apple Intelligence)
```

## Licences

- SigLIP base patch16-224 by Google: Apache 2.0.
- Manrope and JetBrains Mono (from Phase 2): SIL Open Font License.
