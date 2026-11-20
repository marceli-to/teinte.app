import Foundation

/// Maps free words ("dogs", "puppy") to Vision classification identifiers ("dog").
public struct LabelResolver: Sendable {
    public let vocabulary: Set<String>
    private let byFirstComponent: [String: String]

    public init(vocabulary: some Sequence<String>) {
        let vocab = Set(vocabulary.map { $0.lowercased() })
        self.vocabulary = vocab
        var first: [String: String] = [:]
        for id in vocab.sorted(by: { $0.count < $1.count }) {
            guard let head = id.split(separator: "_").first.map(String.init), head != id else { continue }
            if first[head] == nil { first[head] = id }
        }
        byFirstComponent = first
    }

    public static let empty = LabelResolver(vocabulary: [])

    /// Words that are never treated as object labels, even if the taxonomy has them:
    /// they describe light, mood or time, which embedding search handles better.
    public static let excluded: Set<String> = [
        "light", "dark", "warm", "cool", "cold", "soft", "bright", "evening", "morning", "afternoon",
        "night", "day", "cozy", "cosy", "moody", "calm", "minimal", "vintage", "retro", "close-up",
        "closeup", "detail", "texture", "pattern", "shot", "shots", "photo", "image", "picture",
    ]

    static let synonyms: [String: String] = [
        "puppy": "dog", "puppies": "dog", "doggy": "dog", "dogs": "dog",
        "kitten": "cat", "kittens": "cat", "kitty": "cat",
        "automobile": "car", "automobiles": "car",
        "bicycle": "bicycle", "bike": "bicycle", "bikes": "bicycle",
        "meal": "food", "meals": "food", "dish": "food", "dishes": "food",
        "seaside": "beach", "shore": "beach",
        "ship": "boat", "ships": "boat", "sailboat": "sailboat",
        "flowers": "flower", "blossom": "flower", "blossoms": "flower",
        "mountains": "mountain", "hills": "hill",
        "trees": "tree", "forest": "forest", "woods": "forest",
        "ocean": "ocean", "lake": "lake",
        "building": "building", "buildings": "building", "architecture": "building",
        "house": "house_single", "houses": "house_single", "home": "house_single", "homes": "house_single",
        "city": "cityscape", "cities": "cityscape",
    ]

    /// Vision rarely says "building" with confidence: a red brick facade comes back as "structure",
    /// "balcony", "apartment" or "storefront". A query label matches any identifier in its group.
    static let related: [String: [String]] = [
        "building": [
            "skyscraper", "apartment", "domicile", "house_single", "storefront", "tower", "clock_tower",
            "belltower", "castle", "barn", "shed", "lighthouse", "windmill", "cityscape",
        ],
        "house_single": ["domicile", "apartment", "barn", "shed"],
        "car": ["automobile"],
        "automobile": ["car"],
    ]

    /// The identifiers that satisfy a resolved label: itself plus its related group (only ones Vision knows).
    public func group(for identifier: String) -> [String] {
        [identifier] + (Self.related[identifier] ?? []).filter { vocabulary.isEmpty || vocabulary.contains($0) }
    }

    /// The Vision identifier for `word`, or nil if it doesn't map to one.
    public func resolve(_ word: String) -> String? {
        let w = word.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
        guard !w.isEmpty, !Self.excluded.contains(w) else { return nil }
        var candidates = [w]
        if let s = Self.synonyms[w] { candidates.append(s) }
        candidates.append(contentsOf: Self.singulars(of: w))
        for c in candidates where vocabulary.contains(c) { return c }
        for c in candidates { if let id = byFirstComponent[c] { return id } }
        return nil
    }

    /// Display form of an identifier: "water_body" → "water body".
    public static func displayName(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: " ")
    }

    static func singulars(of w: String) -> [String] {
        var out: [String] = []
        if w.hasSuffix("ies"), w.count > 4 { out.append(String(w.dropLast(3)) + "y") }
        if w.hasSuffix("ves"), w.count > 4 { out.append(String(w.dropLast(3)) + "f") }
        for suffix in ["ches", "shes", "sses", "xes", "oes"] where w.hasSuffix(suffix) {
            out.append(String(w.dropLast(2)))
        }
        if w.hasSuffix("s"), !w.hasSuffix("ss"), w.count > 3 { out.append(String(w.dropLast())) }
        if w == "people" || w == "persons" { out.append("person") }
        if w == "children" { out.append("child") }
        if w == "men" { out.append("man") }
        if w == "women" { out.append("woman") }
        return out
    }
}
