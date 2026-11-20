import Foundation

/// Something that turns a sentence into `QueryFilters`.
public protocol QueryParsing: Sendable {
    var name: String { get }
    func parse(_ sentence: String) async throws -> QueryFilters
}

/// Deterministic, offline parser. Used when Foundation Models is unavailable, and as the test reference.
///
/// It works on a token list, marks tokens as consumed when a pattern uses them, and treats whatever
/// is left (minus boilerplate like "show me images") as labels or free text.
public struct RuleBasedParser: QueryParsing {
    public let name = "rules"
    public var labelResolver: LabelResolver

    public init(labelResolver: LabelResolver = .empty) {
        self.labelResolver = labelResolver
    }

    public func parse(_ sentence: String) async throws -> QueryFilters { parseSync(sentence) }

    public func parseSync(_ sentence: String) -> QueryFilters {
        var state = ParseState(sentence)
        var filters = QueryFilters()

        filters.text = state.matchText()
        filters.faces = state.matchFaces()
        filters.orientation = state.matchOrientation()
        filters.people = state.matchPeople()
        filters.colours = state.matchColours()

        // Remaining tokens: labels if Vision knows them, otherwise free text.
        for i in state.tokens.indices where !state.tokens[i].consumed {
            let t = state.tokens[i].text
            guard !Lexicon.boilerplate.contains(t), !Lexicon.connectors.contains(t) else { continue }
            if let id = labelResolver.resolve(t) {
                filters.labels.append(id)
                state.tokens[i].consumed = true
            }
        }
        filters.freeText = state.residualText()
        return filters.normalized()
    }
}

// MARK: - Lexicon

enum Lexicon {
    static let colourWords: [String: ColourBucket] = {
        var m: [String: ColourBucket] = [:]
        let table: [ColourBucket: [String]] = [
            .red: ["red", "reds", "crimson", "scarlet", "maroon", "burgundy", "ruby", "cherry", "reddish"],
            .orange: ["orange", "oranges", "tangerine", "amber", "rust", "terracotta", "coral", "orangey", "orangish"],
            .yellow: ["yellow", "yellows", "golden", "gold", "mustard", "lemon", "yellowish"],
            .green: ["green", "greens", "olive", "emerald", "sage", "lime", "mint", "greenish"],
            .teal: ["teal", "turquoise", "cyan", "aqua", "aquamarine", "petrol"],
            .blue: ["blue", "blues", "navy", "azure", "cobalt", "cerulean", "denim", "bluish", "blueish", "indigo"],
            .purple: ["purple", "purples", "violet", "lilac", "lavender", "plum", "mauve", "purplish"],
            .pink: ["pink", "pinks", "rose", "fuchsia", "magenta", "blush", "salmon", "pinkish"],
            .brown: ["brown", "browns", "beige", "tan", "chocolate", "coffee", "khaki", "bronze", "caramel", "brownish"],
            .black: ["black", "blacks", "ebony", "jet-black"],
            .white: ["white", "whites", "cream", "ivory", "snow-white", "off-white", "whitish"],
            .grey: ["grey", "gray", "greys", "grays", "silver", "charcoal", "greyish", "grayish"],
        ]
        for (bucket, words) in table { for w in words { m[w] = bucket } }
        return m
    }()

    static let numbers: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "a": 1, "single": 1,
    ]

    static let personSingular: Set<String> = [
        "person", "human", "man", "woman", "kid", "child", "boy", "girl", "figure", "adult", "guy",
        "individual", "someone", "somebody", "lady", "gentleman",
    ]
    static let personPlural: Set<String> = [
        "people", "persons", "humans", "men", "women", "kids", "children", "boys", "girls", "figures",
        "adults", "guys", "individuals", "folks", "friends", "ladies", "family", "families",
    ]
    static var personNouns: Set<String> { personSingular.union(personPlural) }

    static let imageNouns: Set<String> = [
        "image", "images", "photo", "photos", "picture", "pictures", "pic", "pics", "shot", "shots",
        "photograph", "photographs", "snap", "snaps", "frames", "files", "ones",
    ]

    static let negations: Set<String> = ["no", "without", "not", "nothing", "zero", "except", "free", "lacking"]
    static let mostlyModifiers: Set<String> = [
        "mostly", "mainly", "predominantly", "dominantly", "largely", "primarily", "entirely",
        "completely", "all", "very", "full", "dominated", "fully", "deep", "overwhelmingly",
    ]
    static let containsModifiers: Set<String> = [
        "bit", "some", "touch", "hint", "splash", "accent", "accents", "little", "few", "pop", "pops",
        "dash", "bits", "traces", "trace", "spots", "details", "with", "containing", "including", "featuring",
    ]

    /// Always dropped from free text.
    static let boilerplate: Set<String> = [
        "show", "me", "only", "find", "give", "get", "display", "list", "please", "i", "want", "need",
        "looking", "search", "it", "them", "those", "these", "image", "images", "photo", "photos",
        "picture", "pictures", "pic", "pics", "photograph", "photographs", "everything", "anything",
        "stuff", "ones", "just",
    ]
    /// Dropped only at the edges of free text ("sunset over a lake" keeps its "over a").
    static let connectors: Set<String> = [
        "with", "of", "and", "or", "but", "a", "an", "the", "in", "on", "at", "that", "which", "are",
        "is", "some", "any", "to", "there", "where", "for", ",", "has", "have", "having", "where",
        "containing", "featuring", "including", "showing", "who", "by", "from", "into",
    ]
}

// MARK: - Parse state

struct ParseState {
    struct Token { var text: String; var consumed = false }

    var tokens: [Token] = []
    /// Fragments lifted out before tokenising ("black and white").
    var fragments: [String] = []

    init(_ sentence: String) {
        var s = " " + sentence.lowercased() + " "
        // Phrases that look like colours but mean something else.
        let monochrome = ["black-and-white", "black and white", "black & white", "b&w", "b & w", "monochrome", "greyscale", "grayscale"]
        for phrase in monochrome where s.contains(phrase) {
            s = s.replacingOccurrences(of: phrase, with: " ")
            fragments.append("black and white")
        }
        var current = ""
        func flush() {
            if !current.isEmpty { tokens.append(Token(text: current)); current = "" }
        }
        for ch in s {
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "'" || ch == "+" || ch == "&" {
                current.append(ch)
            } else if ch == "," || ch == ";" {
                flush(); tokens.append(Token(text: ","))
            } else {
                flush()
            }
        }
        flush()
        // "3+" → "3", "+"
        tokens = tokens.flatMap { t -> [Token] in
            if t.text.count > 1, t.text.hasSuffix("+") { return [Token(text: String(t.text.dropLast())), Token(text: "+")] }
            return [t]
        }
    }

    func text(_ i: Int) -> String? { tokens.indices.contains(i) ? tokens[i].text : nil }
    func free(_ i: Int) -> Bool { tokens.indices.contains(i) && !tokens[i].consumed }

    mutating func consume(_ range: ClosedRange<Int>) {
        for i in range where tokens.indices.contains(i) { tokens[i].consumed = true }
    }

    /// Index of the previous unconsumed-or-consumed token skipping fillers like "any", "a".
    func previous(from i: Int, skipping skip: Set<String>) -> Int? {
        var j = i - 1
        while j >= 0 {
            if !skip.contains(tokens[j].text) { return j }
            j -= 1
        }
        return nil
    }

    static func number(_ s: String?) -> Int? {
        guard let s else { return nil }
        if let n = Int(s) { return n }
        return Lexicon.numbers[s]
    }

    // MARK: Text

    mutating func matchText() -> Presence? {
        let nouns: Set<String> = ["text", "texts", "words", "writing", "lettering", "letters", "captions", "caption", "typography", "signage"]
        var result: Presence?
        for i in tokens.indices {
            let t = tokens[i].text
            if t == "text-free" || t == "textless" { consume(i...i); result = result ?? .without; continue }
            if t == "screenshot" || t == "screenshots" { result = result ?? .with; continue }
            guard nouns.contains(t), free(i) else { continue }
            var start = i
            var negated = false
            var j = i - 1
            while j >= 0, ["any", "visible", "readable", "some", "a", "of"].contains(tokens[j].text) { j -= 1 }
            if j >= 0, Lexicon.negations.contains(tokens[j].text) {
                negated = true; start = j
                if j >= 1, tokens[j - 1].text == "with" { start = j - 1 } // "with no text"
            } else if j >= 0, ["with", "containing", "has", "have", "showing", "including"].contains(tokens[j].text) {
                start = j
            } else {
                start = j + 1
            }
            consume(start...i)
            result = result ?? (negated ? .without : .with)
        }
        return result
    }

    // MARK: Faces

    mutating func matchFaces() -> Presence? {
        var result: Presence?
        for i in tokens.indices where free(i) {
            let t = tokens[i].text
            if t == "face" || t == "faces" {
                var j = i - 1
                while j >= 0, ["any", "visible", "a", "close-up", "closeup", "human"].contains(tokens[j].text) { j -= 1 }
                if j >= 0, Lexicon.negations.contains(tokens[j].text) {
                    consume(j...j); consume(i...i); result = result ?? .without
                } else {
                    if j >= 0, tokens[j].text == "with" { consume(j...j) }
                    consume(i...i); result = result ?? .with
                }
            } else if t == "portrait" || t == "portraits" || t == "selfie" || t == "selfies" || t == "headshot" || t == "headshots" {
                // Photographic genre (not orientation): implies a face, and stays in free text.
                let next = text(i + 1)
                if let next, ["format", "orientation", "mode", "oriented", "aspect"].contains(next) { continue }
                result = result ?? .with
            }
        }
        return result
    }

    // MARK: Orientation

    mutating func matchOrientation() -> Orientation? {
        let formatWords: Set<String> = ["format", "orientation", "mode", "oriented", "aspect"]
        var result: Orientation?
        for i in tokens.indices where free(i) {
            let t = tokens[i].text
            let next = text(i + 1)
            switch t {
            case "vertical", "tall", "upright":
                consume(i...i); result = result ?? .portrait
            case "portrait" where next.map(formatWords.contains) == true:
                consume(i...(i + 1)); result = result ?? .portrait
            case "horizontal", "widescreen", "panorama", "panoramas", "panoramic":
                consume(i...i); result = result ?? .landscape
            case "wide" where next.map(Lexicon.imageNouns.contains) == true || next == nil:
                consume(i...i); result = result ?? .landscape
            case "landscape" where next.map({ formatWords.contains($0) || Lexicon.imageNouns.contains($0) }) == true:
                consume(next.map(formatWords.contains) == true ? i...(i + 1) : i...i)
                result = result ?? .landscape
            case "square", "squares", "square-format", "squared":
                consume(i...i); result = result ?? .square
            default:
                break
            }
        }
        return result
    }

    // MARK: People

    mutating func matchPeople() -> PeopleFilter? {
        var result: PeopleFilter?
        func set(_ p: PeopleFilter) { if result == nil { result = p } }

        var i = 0
        while i < tokens.count {
            defer { i += 1 }
            guard free(i) else { continue }
            let t = tokens[i].text

            // Whole-word "nobody"-style.
            if ["nobody", "noone", "empty", "deserted", "unpeopled", "uninhabited", "unpopulated"].contains(t) {
                consume(i...i); set(.none); continue
            }
            // "no one" / "no people" / "without any people" / "zero people"
            if Lexicon.negations.contains(t) {
                var j = i + 1
                while let n = text(j), ["any", "other", "visible", "a"].contains(n) { j += 1 }
                if let n = text(j), Lexicon.personNouns.contains(n) || (n == "one" && !(text(j + 1).map(Lexicon.personNouns.contains) ?? false)) {
                    consume(i...j); set(.none); continue
                }
            }
            // "at least 3 (people)", "more than 2 people", "minimum 4"
            if (t == "at" && text(i + 1) == "least") || t == "min" || t == "minimum" || (t == "more" && text(i + 1) == "than") || t == "over" {
                let numIndex = (t == "at" || t == "more") ? i + 2 : i + 1
                if let n = Self.number(text(numIndex)) {
                    let nounIndex = numIndex + 1
                    let hasNoun = text(nounIndex).map(Lexicon.personNouns.contains) ?? false
                    if hasNoun || result == nil && groupContext(before: i) {
                        let value = t == "more" || t == "over" ? n + 1 : n
                        consume(i...(hasNoun ? nounIndex : numIndex)); set(.atLeast(value)); continue
                    }
                }
            }
            // "groups of four people", "group of people", "groups"
            if t == "group" || t == "groups" {
                var j = i + 1
                if text(j) == "of" { j += 1 }
                if text(j) == "at", text(j + 1) == "least", let n = Self.number(text(j + 2)) {
                    let end = text(j + 3).map(Lexicon.personNouns.contains) == true ? j + 3 : j + 2
                    consume(i...end); set(.atLeast(n)); continue
                }
                if let n = Self.number(text(j)), text(j) != "a" {
                    let end = text(j + 1).map(Lexicon.personNouns.contains) == true ? j + 1 : j
                    consume(i...end); set(.atLeast(n)); continue
                }
                let end = text(j).map(Lexicon.personNouns.contains) == true ? j : i
                consume(i...end); set(.atLeast(3)); continue
            }
            if t == "crowd" || t == "crowds" || t == "crowded" {
                consume(i...i); set(.atLeast(5)); continue
            }
            // "3 or more people", "3+ people"
            if let n = Self.number(t), t != "a", t != "single" {
                if text(i + 1) == "or", text(i + 2) == "more" {
                    let end = text(i + 3).map(Lexicon.personNouns.contains) == true ? i + 3 : i + 2
                    consume(i...end); set(.atLeast(n)); continue
                }
                if text(i + 1) == "+" {
                    let end = text(i + 2).map(Lexicon.personNouns.contains) == true ? i + 2 : i + 1
                    consume(i...end); set(.atLeast(n)); continue
                }
            }
            // "a couple of people", "a pair"
            if t == "couple" || t == "couples" || t == "pair" {
                var start = i, end = i
                if i > 0, tokens[i - 1].text == "a" { start = i - 1 }
                if text(i + 1) == "of", text(i + 2).map(Lexicon.personNouns.contains) == true { end = i + 2 }
                consume(start...end); set(.exactly(2)); continue
            }
            // "exactly two people", "one person", "a single person", "a woman"
            if let noun = text(i + 1), Lexicon.personNouns.contains(noun) || (t == "single" && text(i + 2).map(Lexicon.personNouns.contains) == true) {
                let nounIndex = Lexicon.personNouns.contains(noun) ? i + 1 : i + 2
                var count: Int?
                if t == "a" || t == "an" || t == "one" || t == "single" || t == "lone" || t == "sole" {
                    count = Lexicon.personSingular.contains(tokens[nounIndex].text) ? 1 : nil
                    if t == "single" || t == "lone" { count = 1 }
                } else if let n = Self.number(t) {
                    count = n
                }
                if t == "a", text(i + 1) == "single" { count = 1 }
                if let count {
                    var start = i
                    if i > 0, ["exactly", "just", "only", "precisely"].contains(tokens[i - 1].text) { start = i - 1 }
                    if i > 0, tokens[i - 1].text == "a", t == "single" { start = i - 1 }
                    if start > 0, ["exactly", "just", "only"].contains(tokens[start - 1].text) { start -= 1 }
                    consume(start...nounIndex); set(.exactly(count)); i = nounIndex; continue
                }
            }
            if t == "alone" || t == "solo" {
                consume(i...i); set(.exactly(1)); continue
            }
            // Bare plural ("with people") → any.
            if Lexicon.personNouns.contains(t) {
                var start = i
                if i > 0, ["with", "containing", "featuring", "including", "of", "some", "any"].contains(tokens[i - 1].text) { start = i - 1 }
                if start > 0, ["with", "containing", "featuring", "including"].contains(tokens[start - 1].text) { start -= 1 }
                var end = i
                if text(i + 1) == "in", text(i + 2) == "it" { end = i + 2 }
                consume(start...end); set(.any); continue
            }
        }
        return result
    }

    private func groupContext(before i: Int) -> Bool {
        i > 0 && ["group", "groups", "of"].contains(tokens[i - 1].text)
    }

    // MARK: Colours

    mutating func matchColours() -> [ColourFilter] {
        let fillers: Set<String> = ["any", "a", "of", "the", "and", "or", ",", "lot", "lots", "in", "little"]
        let colourNouns: Set<String> = ["tones", "tone", "toned", "colours", "colors", "colour", "color", "hues", "palette"]
        var result: [ColourFilter] = []

        for i in tokens.indices where free(i) {
            guard let bucket = Lexicon.colourWords[tokens[i].text] else { continue }
            let word = tokens[i].text
            var mode: ColourMode?
            var sawContains = false
            var start = i

            // Look back for a modifier. Passes over fillers and earlier colours in a list,
            // so "no red or orange" and "mostly blue and white" apply to both colours.
            var j = i - 1
            var lowest = i
            while j >= 0 {
                let p = tokens[j].text
                if Lexicon.negations.contains(p) { mode = .without; lowest = j; break }
                if Lexicon.mostlyModifiers.contains(p) { mode = .mostly; lowest = j; break }
                if p == "with" || p == "containing" || p == "including" || p == "featuring" {
                    if j == i - 1 { sawContains = true; lowest = j }
                    break
                }
                if Lexicon.containsModifiers.contains(p) { sawContains = true; lowest = j; j -= 1; continue }
                if fillers.contains(p) || Lexicon.colourWords[p] != nil { j -= 1; continue }
                break
            }
            if mode == nil, sawContains { mode = .contains }
            if mode != nil { start = lowest }
            if mode == nil, word.hasSuffix("ish") || word == "orangey" { mode = .contains }

            // Look ahead: a colour in front of a noun that isn't the image itself
            // ("teal water", "orange and pink sunset") describes only part of it.
            if mode == nil {
                var k = i + 1
                while let n = text(k), Lexicon.colourWords[n] != nil || ["and", "or", ",", "-"].contains(n) { k += 1 }
                if let n = text(k), !Lexicon.imageNouns.contains(n), !Lexicon.connectors.contains(n),
                   !Lexicon.negations.contains(n), !Lexicon.boilerplate.contains(n), !colourNouns.contains(n) {
                    mode = .contains
                }
            }

            var end = i
            if let n = text(i + 1), colourNouns.contains(n) { end = i + 1 }
            consume(start...end)
            // List glue between two colours ("orange and pink").
            if i >= 2, ["and", "or", ","].contains(tokens[i - 1].text), Lexicon.colourWords[tokens[i - 2].text] != nil {
                consume((i - 1)...(i - 1))
            }
            result.append(ColourFilter(bucket, mode ?? .mostly))
        }
        return result
    }

    // MARK: Residual

    func residualText() -> String? {
        var words: [String] = []
        for t in tokens where !t.consumed {
            if Lexicon.boilerplate.contains(t.text) || t.text == "+" { continue }
            words.append(t.text)
        }
        while let f = words.first, Lexicon.connectors.contains(f) { words.removeFirst() }
        while let l = words.last, Lexicon.connectors.contains(l) { words.removeLast() }
        // Collapse runs of connectors left by removed spans ("water with and a boat" → handled at edges).
        var cleaned: [String] = []
        for w in words {
            if w == ",", cleaned.last == "," { continue }
            cleaned.append(w)
        }
        let body = cleaned.joined(separator: " ").replacingOccurrences(of: " ,", with: ",")
        let all = (fragments + (body.isEmpty ? [] : [body])).joined(separator: " ")
        return all.isEmpty ? nil : all
    }
}
