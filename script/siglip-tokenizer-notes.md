# SigLIP tokenizer: what the Swift port has to reproduce

Reference: `transformers` 4.57.6 `SiglipTokenizer` (the slow, SentencePiece-backed tokenizer; the
`google/siglip-base-patch16-224` repo has no fast tokenizer class), called as

```python
tok(text, padding="max_length", max_length=64, truncation=True)["input_ids"]
```

Data: `Teinte/Resources/Models/siglip-vocab.json` (exported from `spiece.model` by
`script/convert-siglip.py`). Golden output: `Packages/TeinteCore/Tests/TeinteCoreTests/Fixtures/siglip_tokens.json`.

`script/convert-siglip.py` contains `ReferenceTokenizer`, a ~80-line pure-Python port of exactly the
steps below. It is checked against HF on the 45 fixtures plus 3,000 random strings (mixed case, ASCII and
Unicode punctuation, accents, combining marks, CJK, emoji with ZWJ/VS16, fullwidth forms, ligatures,
tabs/newlines, NBSP, ZWSP, U+2581). Result: **3045/3045 identical**. If the Swift code follows
`ReferenceTokenizer` step for step, it will match.

## Constants

| | value |
|---|---|
| vocab | 32,000 pieces, SentencePiece **unigram** |
| `<pad>` | id 0, **not used** by the HF tokenizer |
| `</s>` (EOS, also the HF pad token) | id 1 |
| `<unk>` | id 2 |
| byte pieces `<0x00>`…`<0xFF>` | ids 3…258 (id = 3 + byte) |
| normal pieces | ids 259…31999 (31,741 pieces), max length 16 code points |
| min normal score | −14.118217 → unk score = min − 10 = **−24.118217** |
| byte_fallback | **true** |
| max length | 64 = up to 63 content ids + EOS, right-padded with **1** |

Piece types in `siglip-vocab.json` `"types"`: `control` (0, 1), `unknown` (2), `byte` (3–258),
`normal` (rest). There are no `user_defined` or `unused` pieces.

## Pipeline

### 1. Lowercase, one code point at a time

`do_lower_case=True` in `tokenizer_config.json`. The base class `PreTrainedTokenizer.tokenize` does:

```python
if hasattr(self, "do_lower_case") and self.do_lower_case:
    # convert non-special tokens to lowercase. Might be super slow as well?
    escaped_special_toks = [re.escape(s_tok) for s_tok in (self.all_special_tokens)]
    ...
    pattern = r"(" + r"|".join(escaped_special_toks) + r")|" + r"(.+?)"
    text = re.sub(pattern, lambda m: m.groups()[0] or m.groups()[1].lower(), text)
```

`(.+?)` matches **one character**, so each code point is lowercased in isolation with Python's full
lowercase mapping (`str.lower`). Consequences:
- No context-sensitive rules: `"ΟΔΟΣ"` → `"οδοσ"` (σ U+03C3, not final ς U+03C2). Swift's
  `String.lowercased()` applies the final-sigma rule and would differ. Use per-scalar
  `Unicode.Scalar.Properties.lowercaseMapping` instead.
- Mappings can expand: `"İ"` (U+0130) → `"i̇"` (`i` + U+0307). The fixture `"İstanbul"` covers this.
- The literal special tokens `</s>` / `<unk>` / (pad = `</s>`) are not lowercased; see step 0 below.

### 0. (Edge case) literal special tokens in the input

Before `_tokenize`, the base class splits the text on literal `</s>` and `<unk>` (both are `AddedToken`
with `lstrip=True, rstrip=True`, so whitespace on both sides of them is eaten) and emits their ids
directly. Users typing `</s>` into a photo search box is not a real case; the Swift port can ignore it.
None of the fixtures contain these literals.

### Where steps 2–4 come from

```python
# tokenization_siglip.py
def tokenize(self, text, add_special_tokens=False, **kwargs):
    tokens = super().tokenize(SPIECE_UNDERLINE + text.replace(SPIECE_UNDERLINE, " "), **kwargs)
    if len(tokens) > 1 and tokens[0] == SPIECE_UNDERLINE and tokens[1] in self.all_special_tokens:
        tokens = tokens[1:]
    return tokens

def remove_punctuation(self, text: str) -> str:
    return text.translate(str.maketrans("", "", string.punctuation))

# source: big_vision/evaluators/proj/image_text/prompt_engineering.py#L94
def canonicalize_text(self, text, *, keep_punctuation_exact_string=None):
    if keep_punctuation_exact_string:
        ...
    else:
        text = self.remove_punctuation(text)
    text = re.sub(r"\s+", " ", text)
    text = text.strip()
    return text

def _tokenize(self, text, **kwargs):
    text = self.canonicalize_text(text, keep_punctuation_exact_string=None)
    tokens = self.sp_model.encode(text, out_type=str)
    # 1. Encode string + prefix ex: "<unk> Hey"
    tokens = self.sp_model.encode(self.unk_token + text, out_type=str)
    # 2. Remove self.unk_token from ['<','unk','>', '▁Hey']
    return tokens[self.unk_token_length :] if len(tokens) >= self.unk_token_length else tokens
```

and the SentencePiece model is loaded with `add_dummy_prefix` forced to **false**:

```python
normalizer_spec = model_pb2.NormalizerSpec()
normalizer_spec.add_dummy_prefix = False
model.normalizer_spec.MergeFrom(normalizer_spec)
```

So HF prepends its own `▁` (U+2581) and protects it from SentencePiece's leading-whitespace trimming
by encoding `"<unk>" + text` and dropping the first 4 pieces (`<`, `un`, `k`, `>`). The net effect is
equivalent to the plain steps below.

### 2. Replace U+2581 with a space

`text.replace("▁", " ")`. (The `▁` HF prepends is not affected by later steps, see step 6.)

### 3. Remove ASCII punctuation

Delete every character of Python's `string.punctuation`, exactly these 32:

```
!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~
```

Characters are **deleted, not replaced by a space**: `"black-and-white"` → `"blackandwhite"`,
`"IMG_2041.jpg"` → `"img2041jpg"`, `"it's"` → `"its"`. Non-ASCII punctuation (`— “ ” … ¿ ¡ ’ «`)
is **kept** and goes on to SentencePiece.

### 4. Collapse whitespace, strip

`re.sub(r"\s+", " ", text).strip()`. Python's `\s` (str patterns) is exactly these code points:

```
0009 000A 000B 000C 000D 001C 001D 001E 001F 0020 0085 00A0 1680
2000–200A 2028 2029 202F 205F 3000
```

Note: U+200B (ZWSP), U+200D (ZWJ), U+FEFF are **not** in this set (they're handled in step 5).
`.strip()` strips the same set. Don't use Swift's `Character.isWhitespace` (different set); use this list.

### 5. SentencePiece normalisation: `nmt_nfkc`

From the `spiece.model` `normalizer_spec`: `name = "nmt_nfkc"`, `add_dummy_prefix = true` (but forced
off by HF), `remove_extra_whitespaces = true`, `escape_whitespaces = true`.

`nmt_nfkc` is NFKC plus NMT-specific rules, stored as a precompiled charsmap. It was measured against
Python's NFKC (Unicode 15.0) over every code point; the 181 code points where it differs are in
`siglip-vocab.json` → `normalizer.overrides` (hex code point → replacement):

- `""` (deleted): C0 controls except tab/LF/CR/FF (`0001`–`0008`, `000B`, `000E`–`001F`), `007F`,
  `008F`, `009F`.
- `" "` (becomes whitespace): `0009 000A 000C 000D 1680 200B 200C 200D 200E 200F 2028 2029 FEFF FFFD`.
  So an emoji ZWJ sequence `👨‍👩‍👧` becomes three emoji separated by spaces.
- itself (kept verbatim; NFKC would change it): 136 code points: `32FF`, `A7F2`–`A7F4`, `AB69`,
  `FF5E` (fullwidth tilde), `10781`–`107BA` (minus 2), `1E030`–`1E06D`, `1F16C`, `1F23B`,
  `1FBF0`–`1FBF9`. Mostly characters newer than the charsmap.
- `0344` (combining dialytika tonos) → U+0308 U+0301, without recomposing with the preceding letter.

Algorithm: walk the code points; an override code point is replaced by its table value **without**
NFKC; every maximal run of non-override code points is NFKC-normalised as a run (so `e` + U+0301
composes to `é`). Swift: `String.precomposedStringWithCompatibilityMapping` per run.

Caveat: macOS 26's NFKC uses a newer Unicode version than 15.0; code points added after Unicode 15.0
that have compatibility decompositions could differ. Irrelevant for real queries.

### 6. SentencePiece whitespace handling, then the `▁` prefix

- Collapse runs of U+0020 into one, trim leading and trailing U+0020.
- If the result is empty → **no content tokens** (so `""`, `" "`, `"!!!"` give `[1, 1, …, 1]`).
- Otherwise: replace each U+0020 with `▁` (U+2581) and prepend one `▁`.

Example: `"Café Zürich!"` → `"▁café▁zürich"`.

### 7. Unigram Viterbi segmentation (with byte fallback)

Positions are **Unicode scalars**, not Swift `Character`s (grapheme clusters) and not bytes. Scores are
**Float32** and so are the path sums (SentencePiece uses `float`).

Candidate pieces: only pieces of type `normal`. Control, unknown and byte pieces are never matched
from text.

```
best[0] = (score 0, start -1, id -1); best[1...n] = unset
for start in 0..<n:                         # ascending
    base = best[start].score
    hasSingle = false
    for len in 1...min(16, n - start):      # ascending length
        if piece = normalPieces[s[start..<start+len]]:
            cand = base + piece.score       # Float32
            if best[start+len] unset or cand > best[start+len].score:   # strict >
                best[start+len] = (cand, start, piece.id)
            if len == 1: hasSingle = true
    if !hasSingle:                           # no 1-scalar piece for this character
        cand = base + unkScore               # unkScore = minNormalScore - 10 = -24.118217
        if best[start+1] unset or cand > best[start+1].score:
            best[start+1] = (cand, start, UNK)
backtrack from n via start indices
```

On backtrack, an `UNK` node covering scalar `c` is replaced by its UTF-8 bytes as byte pieces:
id = 3 + byte, in byte order. E.g. `🐶` (F0 9F 90 B6) → `[243, 162, 147, 185]`; `ï` → `[198, 178]`.
(SentencePiece merges adjacent unknowns into one before byte fallback; the output ids are the same.)

Vocabulary quirk worth knowing: there are no single-letter word pieces like `▁a`, `▁x`, `▁i`, so
`"a photo of a dog"` → `▁ a ▁photo ▁of ▁ a ▁dog` = `[262, 266, 1304, 267, 262, 266, 1571]`.

### 8. EOS, truncation, padding

- `truncation=True` with `max_length=64` truncates the content ids to **63**, then appends EOS `1`
  (`build_inputs_with_special_tokens` → `_add_eos_if_not_present`: EOS is only skipped if the last
  id is already 1, which can only happen with a literal `</s>` in the input).
- Right-pad with the pad id **1** (`pad_token = "</s>"`, `padding_side = "right"`) to exactly 64.
- So every sequence is `content (≤ 63) + [1] + [1]*padding`. Empty input is 64 × `1`.

### 9. No attention mask

`tokenizer_config.json` has `"model_input_names": ["input_ids"]`, so the processor never produces an
attention mask, and the Core ML text encoder has only `input_ids`. The text tower pools the hidden state
at the **last position** (`pooled_output = last_hidden_state[:, -1, :]` in `SiglipTextTransformer`), i.e.
the pad/EOS token at index 63. The input must therefore always be exactly 64 ids padded with 1;
shorter input or a different pad id changes the embedding.

## Quick self-check list for the Swift tests

| text | ids before the EOS/padding |
|---|---|
| `""`, `" "`, `"!!!"` | `[]` |
| `"cozy"` | `[9074]` |
| `"a photo of a dog"` and `"A PHOTO OF A DOG"` | `[262, 266, 1304, 267, 262, 266, 1571]` |
| `"black-and-white"` | `[988, 562, 9832]` |
| `"IMG_2041.jpg"` | `[262, 27574, 2621, 4666, 12166]` |
| `"Café Zürich!"` | `[14983, 262, 761, 5879, 5345]` |
| `"🐶"` | `[262, 243, 162, 147, 185]` |
| `"ΟΔΟΣ"` | `[262, 209, 194, 209, 183, 209, 194, 210, 134]` (σ, not ς) |
| `"İstanbul"` | `[262, 302, 207, 138, 8813, 8385]` |
| `"a photo of " + "very " * 80 + …` | 63 content ids, then `1` at index 63 |
