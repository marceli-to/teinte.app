import Foundation

/// SentencePiece unigram tokenizer for SigLIP's text encoder.
///
/// Mirrors Hugging Face `SiglipTokenizer`:
/// 1. canonicalise the text (strip ASCII punctuation, collapse whitespace, lowercase),
/// 2. SentencePiece normalisation (nmt_nfkc: NFKC plus a few overrides), dummy prefix, spaces → "▁",
/// 3. unigram segmentation (Viterbi over piece log-probs); characters not in the vocabulary fall back to
///    their UTF-8 bytes (`<0xNN>` pieces),
/// 4. append EOS, truncate / pad to `maxLength` with the pad id.
/// Golden token IDs from the reference tokenizer are checked in `SigLIPTokenizerTests`.
public struct SigLIPTokenizer: Sendable {
    public let maxLength: Int
    public let padID: Int32
    public let eosID: Int32
    public let unkID: Int32

    private let pieces: [String: (id: Int32, score: Float)]
    private let maxPieceLength: Int
    private let unkScore: Float
    private let byteFallback: Bool
    /// ID of the `<0x00>` piece; byte b is `byteBase + b`.
    private let byteBase: Int32
    private let overrides: [Unicode.Scalar: String]

    struct VocabFile: Decodable {
        var pieces: [Piece]
        var types: [String]?
        var padId: Int?
        var eosId: Int?
        var unkId: Int?
        var byteFallback: Bool?
        var unkPenalty: Float?
        var normalizer: Normalizer?

        struct Normalizer: Decodable {
            /// Hex code point → replacement ("" = delete, " " = whitespace), applied instead of NFKC.
            var overrides: [String: String]?
        }

        struct Piece: Decodable {
            var text: String
            var score: Float
            init(from decoder: Decoder) throws {
                var c = try decoder.unkeyedContainer()
                text = try c.decode(String.self)
                score = try c.decode(Float.self)
            }
        }
    }

    public init(vocabURL: URL, maxLength: Int = 64) throws {
        let file = try JSONDecoder().decode(VocabFile.self, from: Data(contentsOf: vocabURL))
        var map: [String: (Int32, Float)] = [:]
        var longest = 1
        var minScore = Float.greatestFiniteMagnitude
        var byteBase: Int32 = 3
        for (i, p) in file.pieces.enumerated() {
            let type = file.types.flatMap { i < $0.count ? $0[i] : nil } ?? "normal"
            if type == "byte", p.text == "<0x00>" { byteBase = Int32(i) }
            // Only normal (and user-defined) pieces take part in segmentation.
            guard type == "normal" || type == "user_defined" else { continue }
            if map[p.text] == nil { map[p.text] = (Int32(i), p.score) }
            longest = max(longest, p.text.unicodeScalars.count)
            minScore = min(minScore, p.score)
        }
        pieces = map.mapValues { (id: $0.0, score: $0.1) }
        maxPieceLength = longest
        unkScore = minScore - (file.unkPenalty ?? 10)
        byteFallback = file.byteFallback ?? false
        self.byteBase = byteBase
        var overrides: [Unicode.Scalar: String] = [:]
        for (hex, value) in file.normalizer?.overrides ?? [:] {
            if let v = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(v) { overrides[scalar] = value }
        }
        self.overrides = overrides
        self.maxLength = maxLength
        // SigLIP: pad = eos = 1, unk = 2 (overridable from the vocab file).
        padID = Int32(file.padId ?? 1)
        eosID = Int32(file.eosId ?? 1)
        unkID = Int32(file.unkId ?? 2)
    }

    /// Token IDs, always exactly `maxLength` long.
    public func encode(_ text: String) -> [Int32] {
        var ids = segment(normalize(Self.canonicalize(text)))
        if ids.count > maxLength - 1 { ids = Array(ids.prefix(maxLength - 1)) }
        ids.append(eosID)
        while ids.count < maxLength { ids.append(padID) }
        return ids
    }

    /// HF `SiglipTokenizer.canonicalize_text` + lowercasing: drop ASCII punctuation,
    /// collapse whitespace (Python `\s+`), strip.
    public static func canonicalize(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for s in text.unicodeScalars {
            // Python lowercases code point by code point (Σ → σ, never word-final ς).
            for l in s.properties.lowercaseMapping.unicodeScalars where !asciiPunctuation.contains(l) {
                scalars.append(isPythonWhitespace(l) || l == "\u{2581}" ? " " : l)
            }
        }
        return String(scalars).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    /// Python's `string.punctuation`.
    static let asciiPunctuation = Set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~".unicodeScalars)

    static func isPythonWhitespace(_ s: Unicode.Scalar) -> Bool {
        s.properties.isWhitespace || (0x1C...0x1F).contains(s.value)
    }

    /// SentencePiece `nmt_nfkc` + remove_extra_whitespaces + add_dummy_prefix + escape_whitespaces.
    func normalize(_ text: String) -> String {
        var view = String.UnicodeScalarView()
        for s in text.unicodeScalars {
            if let o = overrides[s] { view.append(contentsOf: o.unicodeScalars) } else { view.append(s) }
        }
        let nfkc = String(view).precomposedStringWithCompatibilityMapping
        let words = nfkc.split(whereSeparator: { $0 == " " || $0.isWhitespace })
        guard !words.isEmpty else { return "" }
        return "▁" + words.joined(separator: "▁")
    }

    /// Viterbi segmentation over Unicode scalars. Input is already normalised ("▁" for spaces, leading "▁").
    func segment(_ normalized: String) -> [Int32] {
        // Unicode scalars, not Characters: "i" + U+0307 must stay two units, as in SentencePiece.
        let chars = Array(normalized.unicodeScalars)
        let n = chars.count
        guard n > 0 else { return [] }
        var best = [Float](repeating: -.infinity, count: n + 1)
        // id == nil marks an unknown single character.
        var back = [(start: Int, id: Int32?)](repeating: (0, nil), count: n + 1)
        best[0] = 0
        for end in 1...n {
            let lowest = max(0, end - maxPieceLength)
            for start in stride(from: end - 1, through: lowest, by: -1) where best[start] > -.infinity {
                if let p = pieces[String(String.UnicodeScalarView(chars[start..<end]))] {
                    let score = best[start] + p.score
                    if score > best[end] { best[end] = score; back[end] = (start, p.id) }
                }
            }
            // Unknown single character, with SentencePiece's penalty, so segmentation never fails.
            if best[end - 1] > -.infinity, best[end] == -.infinity || best[end - 1] + unkScore > best[end] {
                let score = best[end - 1] + unkScore
                if score > best[end] { best[end] = score; back[end] = (end - 1, nil) }
            }
        }
        var path: [(start: Int, end: Int, id: Int32?)] = []
        var pos = n
        while pos > 0 {
            path.append((back[pos].start, pos, back[pos].id))
            pos = back[pos].start
        }
        var ids: [Int32] = []
        for step in path.reversed() {
            if let id = step.id {
                ids.append(id)
            } else if byteFallback {
                for b in String(String.UnicodeScalarView(chars[step.start..<step.end])).utf8 { ids.append(byteBase + Int32(b)) }
            } else if ids.last != unkID {
                ids.append(unkID)
            }
        }
        return ids
    }
}
