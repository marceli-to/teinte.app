import Foundation

/// Builds the text the embedding model ranks with.
///
/// The whole sentence is the best prompt: "red building" keeps the colour bound to the object,
/// which the parsed parts lose ("some red" + "building"). But embedding models read "no people"
/// as "people", so a sentence with a negation falls back to the positive parsed parts.
public enum RankingPrompt {
    public static func make(sentence: String, filters: QueryFilters, hardLabels: [String], softLabels: [String],
                            sentenceIsCurrent: Bool) -> String? {
        if sentenceIsCurrent, let s = fromSentence(sentence) { return s }
        return fromParts(filters: filters, hardLabels: hardLabels, softLabels: softLabels)
    }

    /// "show me red buildings" → "a photo of red buildings". Nil if it's empty or has a negation.
    public static func fromSentence(_ sentence: String) -> String? {
        var words = sentence.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".!?")) }
            .filter { !$0.isEmpty }
        if words.contains(where: { Lexicon.negations.contains($0) || $0 == "nobody" || $0.hasSuffix("n't") }) {
            return nil
        }
        while let f = words.first, Lexicon.boilerplate.contains(f) || Lexicon.connectors.contains(f) {
            words.removeFirst()
        }
        while let l = words.last, Lexicon.boilerplate.contains(l) || Lexicon.connectors.contains(l) {
            words.removeLast()
        }
        guard !words.isEmpty else { return nil }
        return "a photo of " + words.joined(separator: " ")
    }

    /// Positive colours, then labels, then free text: "a photo of red building".
    /// Nil when only colours (or nothing) are left: those rank by colour share instead.
    public static func fromParts(filters: QueryFilters, hardLabels: [String], softLabels: [String]) -> String? {
        let labels = hardLabels.map { LabelResolver.displayName($0 == "house_single" ? "house" : $0) } + softLabels
        let subject = labels + [filters.freeText].compactMap { $0 }
        guard !subject.isEmpty else { return nil }
        let colours = filters.colours.filter { $0.mode != .without }.map(\.bucket.rawValue)
        let parts = colours + subject
        let joined = parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return joined.isEmpty ? nil : "a photo of " + joined
    }
}
