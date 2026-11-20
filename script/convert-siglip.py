#!/usr/bin/env python3
"""Convert google/siglip-base-patch16-224 to Core ML and export tokenizer data for Teinte.

Run from the repo root with the pinned venv (see script/requirements-convert.txt):

    .tools/venv/bin/python script/convert-siglip.py            # everything
    .tools/venv/bin/python script/convert-siglip.py --skip-convert   # json/fixtures/checks only

Outputs (all paths relative to the repo root):
    Teinte/Resources/Models/SigLIPImage.mlpackage   image -> embedding [1,768] (unnormalised)
    Teinte/Resources/Models/SigLIPText.mlpackage    input_ids Int32 [1,64] -> embedding [1,768] (unnormalised)
    Teinte/Resources/Models/siglip-meta.json
    Teinte/Resources/Models/siglip-vocab.json
    Packages/TeinteCore/Tests/TeinteCoreTests/Fixtures/siglip_tokens.json
    Packages/TeinteCore/Tests/TeinteCoreTests/Fixtures/siglip_text_embeddings.json

The model files are downloaded into .tools/hf (HF_HOME) so nothing lands in ~/.cache.
The script is deterministic and safe to rerun; it overwrites its own outputs only.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import random
import re
import shutil
import string
import sys
import unicodedata
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
os.environ.setdefault("HF_HOME", str(REPO / ".tools" / "hf"))
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

import numpy as np  # noqa: E402
import torch  # noqa: E402
from PIL import Image  # noqa: E402

import coremltools as ct  # noqa: E402
from sentencepiece import sentencepiece_model_pb2 as sp_pb2  # noqa: E402
from transformers import SiglipImageProcessor, SiglipModel, SiglipTokenizer  # noqa: E402

HF_ID = "google/siglip-base-patch16-224"
MODEL_ID = "siglip-base-patch16-224"
MAX_TOKENS = 64
IMAGE_SIZE = 224
DIM = 768

MODELS_DIR = REPO / "Teinte" / "Resources" / "Models"
FIXTURES_DIR = REPO / "Packages" / "TeinteCore" / "Tests" / "TeinteCoreTests" / "Fixtures"

# PLAN.md §8, "The 20 example sentences".
PLAN_SENTENCES = [
    "show only blue images with people in it",
    "red photos",
    "pictures with a bit of yellow",
    "nothing green",
    "black and white street photos",
    "landscape images without people",
    "exactly two people",
    "groups of at least four people",
    "a single person on a jetty",
    "screenshots with text",
    "images without any text",
    "close-up faces",
    "vertical photos of dogs",
    "orange and pink sunset over a lake",
    "cozy",
    "mostly white minimal product shots",
    "blue, no people and no text",
    "warm evening light",
    "square images of food",
    "teal water with one person and a boat",
]

EDGE_CASES = [
    "",
    " ",
    "  multiple   spaces ",
    "Café Zürich!",
    "IMG_2041.jpg",
    "a photo of a dog",
    "A PHOTO OF A DOG",
    "Hello, World! How's it going?",
    "black-and-white",
    "100% sure, 3.14 apples & 2,000 pears (#42)",
    "1990s film photo, 35mm",
    "sunset 🌅 at the beach 🏖️",
    "🐶",
    "tab\tseparated\nnew line",
    "naïve façade — “smart quotes” … ellipsis",
    "Ｆｕｌｌｗｉｄｔｈ ①②③",
    "東京の夜景",
    "Straße in München",
    "é combining accent",
    "a photo of {} in the style of x_y",
    "!!!",
    "ΟΔΟΣ",
    "İstanbul",
    "a photo of " + "very " * 80 + "long text that keeps going well past sixty four tokens",
    "a photo of the sky",
]

EMBEDDING_STRINGS = [
    "a photo of a dog",
    "a photo of a blue sea with people",
    "cozy",
    "a photo of red flowers",
]


# --------------------------------------------------------------------------------------
# Loading
# --------------------------------------------------------------------------------------

def load():
    tok = SiglipTokenizer.from_pretrained(HF_ID)
    proc = SiglipImageProcessor.from_pretrained(HF_ID)
    model = SiglipModel.from_pretrained(HF_ID, torch_dtype=torch.float32, attn_implementation="eager").eval()
    return tok, proc, model


def spiece_proto(tok) -> sp_pb2.ModelProto:
    m = sp_pb2.ModelProto()
    m.ParseFromString(Path(tok.vocab_file).read_bytes())
    return m


def hf_ids(tok, text: str) -> list[int]:
    return tok(text, padding="max_length", max_length=MAX_TOKENS, truncation=True)["input_ids"]


# --------------------------------------------------------------------------------------
# Core ML conversion
# --------------------------------------------------------------------------------------

class ImageEncoder(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, pixel_values):
        return self.model.get_image_features(pixel_values=pixel_values)


class TextEncoder(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, input_ids):
        # SigLIP's text tower takes no attention mask (the processor doesn't emit one) and
        # pools the hidden state at the LAST position (index 63), so inputs must always be
        # padded to exactly 64 tokens with the pad id.
        return self.model.get_text_features(input_ids=input_ids)


def set_metadata(mlmodel, description: str):
    mlmodel.author = "Google (SigLIP, google/siglip-base-patch16-224); converted for Teinte"
    mlmodel.license = "Apache-2.0"
    mlmodel.short_description = description
    mlmodel.version = MODEL_ID
    mlmodel.user_defined_metadata["modelID"] = MODEL_ID
    mlmodel.user_defined_metadata["source"] = f"https://huggingface.co/{HF_ID}"


# fp16 weights and compute everywhere except GELU, which stays fp32. GELU has no weights, so
# the package size is unchanged, but fp16 GELU on the CPU (and ANE) costs a lot of accuracy:
# image cosine vs PyTorch on CPU_ONLY was 0.9977 with everything in fp16 and 0.9995 with this.
FP16_EXCEPT_GELU = ct.transform.FP16ComputePrecision(op_selector=lambda op: op.op_type != "gelu")


def convert_image(model, out: Path):
    enc = ImageEncoder(model).eval()
    example = torch.zeros(1, 3, IMAGE_SIZE, IMAGE_SIZE)
    traced = torch.jit.trace(enc, example)
    # SigLIP preprocessing: x/255 then (x-0.5)/0.5  ==  x/127.5 - 1  -> [-1, 1]
    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(
            name="image",
            shape=(1, 3, IMAGE_SIZE, IMAGE_SIZE),
            scale=1.0 / 127.5,
            bias=[-1.0, -1.0, -1.0],
            color_layout=ct.colorlayout.RGB,
        )],
        outputs=[ct.TensorType(name="embedding", dtype=np.float32)],  # fp32 out: plain [Float] in Swift
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS15,
        compute_precision=FP16_EXCEPT_GELU,
    )
    set_metadata(mlmodel, "SigLIP base/16 image encoder. 224x224 RGB in, 768-d image embedding out (NOT L2-normalised).")
    mlmodel.input_description["image"] = "224x224 RGB image, resized directly (no crop), bicubic"
    mlmodel.output_description["embedding"] = "image_embeds [1,768], unnormalised"
    if out.exists():
        shutil.rmtree(out)
    mlmodel.save(str(out))


def convert_text(model, out: Path):
    enc = TextEncoder(model).eval()
    example = torch.ones(1, MAX_TOKENS, dtype=torch.long)
    traced = torch.jit.trace(enc, example)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="input_ids", shape=(1, MAX_TOKENS), dtype=np.int32)],
        outputs=[ct.TensorType(name="embedding", dtype=np.float32)],  # fp32 out: plain [Float] in Swift
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS15,
        compute_precision=FP16_EXCEPT_GELU,
    )
    set_metadata(mlmodel, "SigLIP base/16 text encoder. 64 token ids (pad id 1) in, 768-d text embedding out (NOT L2-normalised).")
    mlmodel.input_description["input_ids"] = "SentencePiece ids, EOS(1)-terminated, right-padded with 1 to length 64"
    mlmodel.output_description["embedding"] = "text_embeds [1,768], unnormalised"
    if out.exists():
        shutil.rmtree(out)
    mlmodel.save(str(out))


def dir_size(p: Path) -> int:
    return sum(f.stat().st_size for f in p.rglob("*") if f.is_file())


# --------------------------------------------------------------------------------------
# Tokenizer export + reference re-implementation (validates script/siglip-tokenizer-notes.md)
# --------------------------------------------------------------------------------------

PIECE_TYPES = {1: "normal", 2: "unknown", 3: "control", 4: "user_defined", 5: "unused", 6: "byte"}


def normalizer_overrides(tok) -> dict[int, str]:
    """Code points where SentencePiece's nmt_nfkc charsmap differs from plain NFKC.

    Measured one code point at a time between two 'x' sentinels, with SentencePiece's own
    whitespace handling (spaces escaped to U+2581, runs collapsed) applied to the NFKC side.
    The returned replacement uses ' ' for "becomes whitespace" and '' for "deleted".
    """
    sp = tok.sp_model
    out: dict[int, str] = {}
    for cp in range(0x110000):
        if 0xD800 <= cp <= 0xDFFF:
            continue
        c = chr(cp)
        # Compare whole strings so that combining marks composing with the sentinel
        # (e.g. 'x' + U+0307 -> U+1E8B) are treated the same on both sides.
        got = sp.normalize("x" + c + "x")
        exp = re.sub(" +", " ", unicodedata.normalize("NFKC", "x" + c + "x")).replace(" ", "\u2581")
        if got != exp:
            assert got.startswith("x") and got.endswith("x"), (hex(cp), got)
            out[cp] = got[1:-1].replace("\u2581", " ")
    return out


class ReferenceTokenizer:
    """Pure-Python port of exactly what the notes describe. Must equal HF SiglipTokenizer."""

    def __init__(self, proto: sp_pb2.ModelProto, overrides: dict[int, str]):
        self.pieces = {}
        self.max_len = 0
        normal_scores = []
        for i, p in enumerate(proto.pieces):
            if p.type == 1:  # NORMAL only; control/unknown/byte pieces are never matched from text
                self.pieces[p.piece] = (i, np.float32(p.score))
                self.max_len = max(self.max_len, len(p.piece))
                normal_scores.append(p.score)
        self.unk_score = np.float32(np.float32(min(normal_scores)) - np.float32(10.0))
        self.byte_base = 3  # '<0x00>' is id 3 ... '<0xFF>' is id 258
        assert proto.pieces[3].piece == "<0x00>" and proto.pieces[258].piece == "<0xFF>"
        self.overrides = overrides
        self.punct = set(string.punctuation)

    def normalize(self, text: str) -> str:
        # HF lowercases with re.sub(r"(...specials...)|(.+?)", ...), i.e. ONE CODE POINT AT A
        # TIME, so context-sensitive rules (Greek final sigma) never apply: "ΟΔΟΣ" -> "οδοσ".
        s = "".join(c.lower() for c in text)
        s = s.replace("▁", " ")
        s = "".join(c for c in s if c not in self.punct)
        s = re.sub(r"\s+", " ", s).strip()
        # SentencePiece nmt_nfkc: overrides verbatim, NFKC for everything else (per run).
        out, run = [], []
        for c in s:
            if ord(c) in self.overrides:
                out.append(unicodedata.normalize("NFKC", "".join(run)))
                run = []
                out.append(self.overrides[ord(c)])
            else:
                run.append(c)
        out.append(unicodedata.normalize("NFKC", "".join(run)))
        s = re.sub(" +", " ", "".join(out)).strip(" ")
        if not s:
            return ""
        return "▁" + s.replace(" ", "▁")

    def viterbi(self, s: str) -> list[int]:
        n = len(s)  # positions are Unicode scalars (code points)
        best = [None] * (n + 1)  # (score, start, id)
        best[0] = (np.float32(0.0), -1, -1)
        for start in range(n):
            base = best[start][0]
            has_single = False
            for length in range(1, min(self.max_len, n - start) + 1):
                hit = self.pieces.get(s[start:start + length])
                if hit is None:
                    continue
                pid, score = hit
                cand = np.float32(base + score)
                end = start + length
                if best[end] is None or cand > best[end][0]:
                    best[end] = (cand, start, pid)
                if length == 1:
                    has_single = True
            if not has_single:
                cand = np.float32(base + self.unk_score)
                end = start + 1
                if best[end] is None or cand > best[end][0]:
                    best[end] = (cand, start, -2)  # unknown -> byte fallback
        ids: list[int] = []
        pos = n
        while pos > 0:
            _, start, pid = best[pos]
            if pid == -2:
                ids[:0] = [self.byte_base + b for b in s[start:pos].encode("utf-8")]
            else:
                ids.insert(0, pid)
            pos = start
        return ids

    def encode(self, text: str) -> list[int]:
        s = self.normalize(text)
        ids = self.viterbi(s) if s else []
        ids = ids[: MAX_TOKENS - 1] + [1]
        return ids + [1] * (MAX_TOKENS - len(ids))


def stress_corpus(seed=1234, n=3000) -> list[str]:
    rng = random.Random(seed)
    words = ("a photo of the dog cat sky sea beach blue red people person street night city "
             "sunset mountain lake boat food portrait selfie screenshot document text tree "
             "flower snow winter summer cozy warm light dark vintage film café zürich straße "
             "naïve façade über jalapeño smörgåsbord crème brûlée").split()
    extras = list(string.punctuation) + list("—–…“”‘’«»¿¡°×÷€£¥©®™") + [
        "🌅", "🐶", "🏖️", "👨‍👩‍👧", "❤️", "東京", "夜景", "Ｆｕｌｌ", "①", "ﬁ", "²", "½",
        "é", " ", "​", "\t", "\n", "  ", "▁", "İ", "ß", "Σ", "ǅ", "ℌ",
        "</s>"[:0], "123", "2041", "IMG_", ".jpg", "35mm", "x_y", "{}", "Ⅻ", "㎏", "ｶﾀｶﾅ",
    ]
    out = []
    for _ in range(n):
        k = rng.randint(0, 12)
        parts = []
        for _ in range(k):
            r = rng.random()
            if r < 0.6:
                w = rng.choice(words)
                if rng.random() < 0.2:
                    w = w.upper()
                elif rng.random() < 0.2:
                    w = w.capitalize()
                parts.append(w)
            else:
                parts.append(rng.choice(extras))
        sep = rng.choice([" ", " ", " ", "", "  ", "-"])
        out.append(sep.join(parts))
    return out


def export_tokenizer(tok, proto, overrides):
    pieces = [[p.piece, p.score] for p in proto.pieces]
    types = [PIECE_TYPES[p.type] for p in proto.pieces]
    ns = proto.normalizer_spec
    vocab = {
        "model": "unigram",
        "source": f"{HF_ID}/spiece.model",
        "pieces": pieces,
        "types": types,
        "unkId": proto.trainer_spec.unk_id,
        "eosId": proto.trainer_spec.eos_id,
        "padId": tok.pad_token_id,
        "byteFallback": proto.trainer_spec.byte_fallback,
        "unkPenalty": 10.0,
        "maxPieceLength": max(len(p.piece) for p in proto.pieces if p.type == 1),
        "normalizer": {
            "name": ns.name,
            "addDummyPrefix": ns.add_dummy_prefix,
            "addDummyPrefixUsedByHF": False,
            "removeExtraWhitespaces": ns.remove_extra_whitespaces,
            "escapeWhitespaces": ns.escape_whitespaces,
            "nfkcReferenceUnicodeVersion": unicodedata.unidata_version,
            "overridesNote": "Code points where nmt_nfkc != NFKC. Apply these verbatim instead of NFKC; "
                             "' ' means the code point becomes whitespace, '' means it is deleted.",
            "overrides": {f"{cp:04X}": rep for cp, rep in sorted(overrides.items())},
        },
    }
    with open(MODELS_DIR / "siglip-vocab.json", "w", encoding="utf-8") as f:
        json.dump(vocab, f, ensure_ascii=False, separators=(",", ":"))
    return vocab


def export_token_fixtures(tok, ref: ReferenceTokenizer):
    texts = PLAN_SENTENCES + EDGE_CASES
    fixtures = []
    for t in texts:
        ids = hf_ids(tok, t)
        assert len(ids) == MAX_TOKENS, (t, len(ids))
        fixtures.append({"text": t, "ids": ids})
    with open(FIXTURES_DIR / "siglip_tokens.json", "w", encoding="utf-8") as f:
        json.dump(fixtures, f, ensure_ascii=False, indent=1)
    # Validate the documented pipeline against HF on the fixtures and a random stress corpus.
    corpus = texts + stress_corpus()
    mismatches = [(t, hf_ids(tok, t), ref.encode(t)) for t in corpus if hf_ids(tok, t) != ref.encode(t)]
    print(f"[tokenizer] fixtures: {len(fixtures)} strings; reference re-implementation vs HF: "
          f"{len(corpus) - len(mismatches)}/{len(corpus)} identical")
    for t, a, b in mismatches[:10]:
        print("  MISMATCH", repr(t), "\n    hf ", a[:24], "\n    ref", b[:24])
    return fixtures, mismatches


# --------------------------------------------------------------------------------------
# Parity checks
# --------------------------------------------------------------------------------------

def cos(a, b) -> float:
    a = np.asarray(a, dtype=np.float64).ravel()
    b = np.asarray(b, dtype=np.float64).ravel()
    return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b)))


def synthetic_images() -> dict[str, Image.Image]:
    imgs = {}
    # Sky: deep blue at the top fading to pale hazy blue near the horizon (landscape, 640x427).
    w, h = 640, 427
    y = np.linspace(0, 1, h)[:, None]
    top, bottom = np.array([20, 70, 170]), np.array([175, 210, 240])
    sky = (top * (1 - y[..., None]) + bottom * y[..., None]).repeat(w, axis=1)
    imgs["sky_gradient"] = Image.fromarray(sky.astype(np.uint8), "RGB")
    # Shapes on a warm background (portrait, 300x500).
    rng = np.random.default_rng(0)
    arr = np.zeros((500, 300, 3), np.uint8)
    arr[...] = (230, 180, 120)
    arr[100:300, 50:250] = (200, 30, 40)
    arr[350:450, 20:280] = (30, 120, 60)
    imgs["shapes"] = Image.fromarray(arr, "RGB")
    # Noise (square, 256x256).
    imgs["noise"] = Image.fromarray(rng.integers(0, 256, (256, 256, 3), dtype=np.uint8), "RGB")
    return imgs


def resize_like_siglip(img: Image.Image) -> Image.Image:
    # SiglipImageProcessor: resize to exactly 224x224 (aspect ratio NOT kept, no crop), resample=3 (BICUBIC).
    return img.convert("RGB").resize((IMAGE_SIZE, IMAGE_SIZE), Image.BICUBIC)


def check_parity(tok, proc, model, image_pkg: Path, text_pkg: Path, compute_units):
    results = {}
    img_ml = ct.models.MLModel(str(image_pkg), compute_units=compute_units)
    txt_ml = ct.models.MLModel(str(text_pkg), compute_units=compute_units)

    img_embs = {}
    for name, img in synthetic_images().items():
        pv = proc(images=img, return_tensors="pt")["pixel_values"]
        resized = resize_like_siglip(img)
        manual = torch.from_numpy(np.asarray(resized, np.float32) / 127.5 - 1.0).permute(2, 0, 1)[None]
        pre_diff = float((pv - manual).abs().max())
        with torch.no_grad():
            ref = model.get_image_features(pixel_values=pv).numpy()
        ml = img_ml.predict({"image": resized})["embedding"]
        assert ml.shape == (1, DIM), ml.shape
        results[f"image:{name}"] = cos(ref, ml)
        img_embs[name] = (ref, ml)
        print(f"  image {name:13s} cos(torch, coreml) = {cos(ref, ml):.6f}   "
              f"(processor vs manual PIL-bicubic max|diff| = {pre_diff:.4f})")

    txt_embs = {}
    for t in EMBEDDING_STRINGS + ["a photo of the sky", "a photo of a dog", PLAN_SENTENCES[0], EDGE_CASES[-2]]:
        ids = hf_ids(tok, t)
        with torch.no_grad():
            ref = model.get_text_features(input_ids=torch.tensor([ids])).numpy()
        ml = txt_ml.predict({"input_ids": np.array([ids], dtype=np.int32)})["embedding"]
        assert ml.shape == (1, DIM), ml.shape
        results[f"text:{t[:40]}"] = cos(ref, ml)
        txt_embs[t] = (ref, ml)
        print(f"  text  {t[:40]!r:44s} cos(torch, coreml) = {cos(ref, ml):.6f}")
    return results, img_embs, txt_embs


def zero_shot(model, img_embs, txt_embs):
    scale = float(model.logit_scale.exp())
    bias = float(model.logit_bias)
    sky_t, sky_c = img_embs["sky_gradient"]
    print("  zero-shot on sky_gradient (cosine | sigmoid(scale*cos+bias)):")
    for t in ["a photo of the sky", "a photo of a dog"]:
        for label, img, txt in (("torch", sky_t, txt_embs[t][0]), ("coreml", sky_c, txt_embs[t][1])):
            c = cos(img, txt)
            p = 1 / (1 + math.exp(-(scale * c + bias)))
            print(f"    {label:6s} {t!r:24s} cos={c:+.4f}  prob={p:.4f}")


# --------------------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--skip-convert", action="store_true", help="reuse existing .mlpackages")
    args = ap.parse_args()

    MODELS_DIR.mkdir(parents=True, exist_ok=True)
    FIXTURES_DIR.mkdir(parents=True, exist_ok=True)
    tok, proc, model = load()
    proto = spiece_proto(tok)

    image_pkg = MODELS_DIR / "SigLIPImage.mlpackage"
    text_pkg = MODELS_DIR / "SigLIPText.mlpackage"
    if not args.skip_convert:
        print("[convert] image encoder ...")
        convert_image(model, image_pkg)
        print("[convert] text encoder ...")
        convert_text(model, text_pkg)

    # Meta
    meta = {
        "modelID": MODEL_ID,
        "dimension": DIM,
        "imageSize": IMAGE_SIZE,
        "maxTokens": MAX_TOKENS,
        "logitScale": float(model.logit_scale.exp()),
        "logitBias": float(model.logit_bias),
        "padId": tok.pad_token_id,
        "eosId": tok.eos_token_id,
        "unkId": tok.unk_token_id,
    }
    with open(MODELS_DIR / "siglip-meta.json", "w") as f:
        json.dump(meta, f, indent=2)
    print("[meta]", meta)

    # Tokenizer
    print("[tokenizer] computing nmt_nfkc overrides (scans all code points) ...")
    overrides = normalizer_overrides(tok)
    export_tokenizer(tok, proto, overrides)
    ref = ReferenceTokenizer(proto, overrides)
    _, mismatches = export_token_fixtures(tok, ref)

    # Text embedding fixtures (PyTorch fp32, unnormalised)
    emb = []
    for t in EMBEDDING_STRINGS:
        ids = hf_ids(tok, t)
        with torch.no_grad():
            e = model.get_text_features(input_ids=torch.tensor([ids]))[0].numpy().astype(np.float32)
        emb.append({"text": t, "ids": ids, "embedding": [float(x) for x in e]})
    with open(FIXTURES_DIR / "siglip_text_embeddings.json", "w") as f:
        json.dump(emb, f)

    # Parity
    worst = 1.0
    for cu_name, cu in (("ALL", ct.ComputeUnit.ALL), ("CPU_ONLY", ct.ComputeUnit.CPU_ONLY)):
        print(f"[parity] compute_units={cu_name}")
        res, img_embs, txt_embs = check_parity(tok, proc, model, image_pkg, text_pkg, cu)
        worst = min(worst, min(res.values()))
        if cu_name == "ALL":
            zero_shot(model, img_embs, txt_embs)

    si, st = dir_size(image_pkg), dir_size(text_pkg)
    print(f"[size] SigLIPImage.mlpackage {si / 1e6:.1f} MB, SigLIPText.mlpackage {st / 1e6:.1f} MB, "
          f"total {(si + st) / 1e6:.1f} MB")
    print(f"[summary] worst cosine {worst:.6f} (threshold 0.999); tokenizer mismatches {len(mismatches)}")
    if worst < 0.999 or mismatches:
        sys.exit(1)


if __name__ == "__main__":
    main()
