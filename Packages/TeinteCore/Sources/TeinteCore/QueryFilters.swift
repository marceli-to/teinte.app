import Foundation

public enum ColourMode: String, Codable, Hashable, Sendable, CaseIterable {
    /// share ≥ 0.33
    case mostly
    /// share ≥ 0.10
    case contains
    /// share < 0.05
    case without

    /// 0.40 with centroid shares (v2). Per-pixel soft shares (v3) spread more; 0.33 gives the same counts.
    public static let mostlyThreshold: Float = 0.33
    public static let containsThreshold: Float = 0.10
    public static let withoutThreshold: Float = 0.05

    public func matches(share: Float) -> Bool {
        switch self {
        case .mostly: share >= Self.mostlyThreshold
        case .contains: share >= Self.containsThreshold
        case .without: share < Self.withoutThreshold
        }
    }
}

/// Which part of the image a colour filter looks at.
public enum ColourRegion: String, Codable, Hashable, Sendable {
    /// The salient part ("a red car").
    case subject
    /// The rest ("on a white background").
    case background
}

public struct ColourFilter: Codable, Hashable, Sendable {
    public var bucket: ColourBucket
    public var mode: ColourMode
    /// Nil = the whole image (subject-weighted).
    public var region: ColourRegion?

    public init(_ bucket: ColourBucket, _ mode: ColourMode, region: ColourRegion? = nil) {
        self.bucket = bucket; self.mode = mode; self.region = region
    }
}

/// Measured tone: from the pixels, no model involved.
public enum LookFilter: String, Codable, Hashable, Sendable, CaseIterable {
    case bright, dark, highContrast, lowContrast, vivid, muted, warm, cool, blackAndWhite

    public var title: String {
        switch self {
        case .highContrast: "high contrast"
        case .lowContrast: "low contrast"
        case .blackAndWhite: "black & white"
        default: rawValue
        }
    }

    /// Thresholds, tuned on a 993-image library (analysis v3) so each look picks roughly
    /// the top 10–15 %: brightness p50 0.56 / p90 0.74, contrast p50 0.20 / p90 0.27,
    /// saturation p50 0.032 / p90 0.065, warmth p10 −0.030 / p50 0.005 / p90 0.046.
    public func matches(_ m: LookMetrics) -> Bool {
        switch self {
        case .bright: m.brightness >= 0.70
        case .dark: m.brightness <= 0.37
        case .highContrast: m.contrast >= 0.27
        case .lowContrast: m.contrast <= 0.12
        case .vivid: m.saturation >= 0.065 && !m.isBlackAndWhite
        case .muted: m.saturation <= 0.02 && !m.isBlackAndWhite
        case .warm: m.warmth >= 0.04 && !m.isBlackAndWhite
        case .cool: m.warmth <= -0.025 && !m.isBlackAndWhite
        case .blackAndWhite: m.isBlackAndWhite
        }
    }

    /// Pairs that can't both apply; the later one wins in `normalized()`.
    var opposite: LookFilter? {
        switch self {
        case .bright: .dark
        case .dark: .bright
        case .highContrast: .lowContrast
        case .lowContrast: .highContrast
        case .vivid: .muted
        case .muted: .vivid
        case .warm: .cool
        case .cool: .warm
        case .blackAndWhite: nil
        }
    }
}

/// Light and style, judged by the embedding model against a fixed prompt.
public enum StyleTag: String, Codable, Hashable, Sendable, CaseIterable {
    case goldenHour, overcast, studioLight, filmGrain, minimal, aerial, macro, night

    public var title: String {
        switch self {
        case .goldenHour: "golden hour"
        case .studioLight: "studio light"
        case .filmGrain: "film grain"
        default: rawValue
        }
    }

    /// The text the image embedding is compared with.
    public var prompt: String {
        switch self {
        case .goldenHour: "a photo taken at golden hour with warm low sunlight"
        case .overcast: "a photo taken on an overcast grey day"
        case .studioLight: "a studio photo with studio lighting and a plain backdrop"
        case .filmGrain: "a grainy analog film photo"
        case .minimal: "a minimalist photo with lots of empty space"
        case .aerial: "an aerial photo taken from above by a drone"
        case .macro: "a macro close-up photo"
        case .night: "a photo taken at night"
        }
    }
}

public enum PeopleFilter: Codable, Hashable, Sendable {
    case any
    case none
    case exactly(Int)
    case atLeast(Int)

    public func matches(count: Int) -> Bool {
        switch self {
        case .any: count >= 1
        case .none: count == 0
        case .exactly(let n): count == n
        case .atLeast(let n): count >= n
        }
    }
}

public enum Presence: String, Codable, Hashable, Sendable {
    case with, without

    public func matches(_ value: Bool) -> Bool { self == .with ? value : !value }
}

public enum Orientation: String, Codable, Hashable, Sendable, CaseIterable {
    case landscape, portrait, square

    /// Square = aspect ratio within ±5 %.
    public init(width: Int, height: Int) {
        guard width > 0, height > 0 else { self = .square; return }
        let ratio = Double(width) / Double(height)
        if abs(ratio - 1) <= 0.05 { self = .square } else { self = ratio > 1 ? .landscape : .portrait }
    }
}

/// The structured meaning of a search sentence.
public struct QueryFilters: Codable, Hashable, Sendable {
    public var colours: [ColourFilter]
    public var people: PeopleFilter?
    public var faces: Presence?
    public var text: Presence?
    public var orientation: Orientation?
    /// Concrete objects / scenes. Each is resolved against the Vision taxonomy; unresolved ones go to `freeText`.
    public var labels: [String]
    /// What's left for embedding search.
    public var freeText: String?
    /// Measured tone (bright, warm, black & white …).
    public var looks: [LookFilter]
    /// Light and style tags (golden hour, aerial …).
    public var styles: [StyleTag]
    /// Words that must appear in the image's recognised text.
    public var textQuery: String?
    /// Screenshots, documents, receipts (Vision's "utility" images).
    public var utility: Presence?
    /// Only images Vision rates as well made.
    public var bestShots: Bool
    /// "Find similar": rank by closeness to this image (content and colour).
    public var similarTo: SimilarSeed?

    public init(
        colours: [ColourFilter] = [], people: PeopleFilter? = nil, faces: Presence? = nil,
        text: Presence? = nil, orientation: Orientation? = nil, labels: [String] = [], freeText: String? = nil,
        looks: [LookFilter] = [], styles: [StyleTag] = [], textQuery: String? = nil, utility: Presence? = nil,
        bestShots: Bool = false, similarTo: SimilarSeed? = nil
    ) {
        self.colours = colours; self.people = people; self.faces = faces; self.text = text
        self.orientation = orientation; self.labels = labels; self.freeText = freeText
        self.looks = looks; self.styles = styles; self.textQuery = textQuery; self.utility = utility
        self.bestShots = bestShots; self.similarTo = similarTo
    }

    // Saved looks from before these fields existed decode with the defaults.
    enum CodingKeys: String, CodingKey {
        case colours, people, faces, text, orientation, labels, freeText, looks, styles, textQuery, utility, bestShots
        case similarTo
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            colours: try c.decodeIfPresent([ColourFilter].self, forKey: .colours) ?? [],
            people: try c.decodeIfPresent(PeopleFilter.self, forKey: .people),
            faces: try c.decodeIfPresent(Presence.self, forKey: .faces),
            text: try c.decodeIfPresent(Presence.self, forKey: .text),
            orientation: try c.decodeIfPresent(Orientation.self, forKey: .orientation),
            labels: try c.decodeIfPresent([String].self, forKey: .labels) ?? [],
            freeText: try c.decodeIfPresent(String.self, forKey: .freeText),
            looks: try c.decodeIfPresent([LookFilter].self, forKey: .looks) ?? [],
            styles: try c.decodeIfPresent([StyleTag].self, forKey: .styles) ?? [],
            textQuery: try c.decodeIfPresent(String.self, forKey: .textQuery),
            utility: try c.decodeIfPresent(Presence.self, forKey: .utility),
            bestShots: try c.decodeIfPresent(Bool.self, forKey: .bestShots) ?? false,
            similarTo: try c.decodeIfPresent(SimilarSeed.self, forKey: .similarTo))
    }

    public static let empty = QueryFilters()

    public var hasStructuredFilters: Bool {
        !colours.isEmpty || people != nil || faces != nil || text != nil || orientation != nil || !labels.isEmpty
            || !looks.isEmpty || !styles.isEmpty || textQuery != nil || utility != nil || bestShots
            || similarTo != nil
    }

    public var isEmpty: Bool { !hasStructuredFilters && (freeText?.isEmpty ?? true) }

    /// Normalises the parser output: dedupes colours (last one wins per bucket), lowercases labels, trims free text.
    public func normalized() -> QueryFilters {
        var copy = self
        var seen = Set<String>()
        copy.colours = colours.reversed().filter { seen.insert("\($0.bucket)/\($0.region?.rawValue ?? "")").inserted }.reversed()
        var looksSeen = Set<LookFilter>()
        copy.looks = looks.reversed().filter { l in
            guard looksSeen.insert(l).inserted else { return false }
            if let o = l.opposite { looksSeen.insert(o) }
            return true
        }.reversed()
        var stylesSeen = Set<StyleTag>()
        copy.styles = styles.filter { stylesSeen.insert($0).inserted }
        let q = textQuery?.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.textQuery = (q?.isEmpty ?? true) ? nil : q
        var labelSeen = Set<String>()
        copy.labels = labels
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && labelSeen.insert($0).inserted }
        let trimmed = freeText?.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.freeText = (trimmed?.isEmpty ?? true) ? nil : trimmed
        if case .exactly(let n) = people, n <= 0 { copy.people = PeopleFilter.none }
        if case .atLeast(let n) = people, n <= 1 { copy.people = .any }
        return copy
    }
}

// MARK: - Chips

/// One removable piece of the parsed query, shown under the search bar.
public struct FilterChip: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        case colour(ColourFilter)
        case people(PeopleFilter)
        case faces(Presence)
        case text(Presence)
        case orientation(Orientation)
        case label(String)
        case freeText(String)
        case look(LookFilter)
        case style(StyleTag)
        case textQuery(String)
        case utility(Presence)
        case bestShots
        case similar(SimilarSeed)
    }

    public var kind: Kind
    public var id: Kind { kind }

    public var title: String {
        switch kind {
        case .colour(let f):
            switch (f.mode, f.region) {
            case (.mostly, .background?): "\(f.bucket.rawValue) background"
            case (.contains, .background?): "some \(f.bucket.rawValue) in the background"
            case (.without, .background?): "no \(f.bucket.rawValue) background"
            case (.mostly, .subject?): "\(f.bucket.rawValue) subject"
            case (.contains, .subject?): "some \(f.bucket.rawValue) in the subject"
            case (.without, .subject?): "no \(f.bucket.rawValue) subject"
            case (.mostly, nil): "mostly \(f.bucket.rawValue)"
            case (.contains, nil): "some \(f.bucket.rawValue)"
            case (.without, nil): "no \(f.bucket.rawValue)"
            }
        case .people(let p):
            switch p {
            case .any: "with people"
            case .none: "no people"
            case .exactly(let n): n == 1 ? "1 person" : "\(n) people"
            case .atLeast(let n): "\(n)+ people"
            }
        case .faces(let p): p == .with ? "with faces" : "no faces"
        case .text(let p): p == .with ? "with text" : "no text"
        case .orientation(let o): o.rawValue
        case .label(let l): l
        case .freeText(let t): "“\(t)”"
        case .look(let l): l.title
        case .style(let t): t.title
        case .textQuery(let q): "text: \(q)"
        case .utility(let p): p == .with ? "screenshots & documents" : "no screenshots"
        case .bestShots: "best shots"
        case .similar(let seed): "like \(seed.fileName)"
        }
    }
}

extension QueryFilters {
    public var chips: [FilterChip] {
        var result: [FilterChip] = similarTo.map { [FilterChip(kind: .similar($0))] } ?? []
        result += colours.map { FilterChip(kind: .colour($0)) }
        if let people { result.append(FilterChip(kind: .people(people))) }
        if let faces { result.append(FilterChip(kind: .faces(faces))) }
        if let text { result.append(FilterChip(kind: .text(text))) }
        if let orientation { result.append(FilterChip(kind: .orientation(orientation))) }
        result += looks.map { FilterChip(kind: .look($0)) }
        result += styles.map { FilterChip(kind: .style($0)) }
        if let textQuery { result.append(FilterChip(kind: .textQuery(textQuery))) }
        if let utility { result.append(FilterChip(kind: .utility(utility))) }
        if bestShots { result.append(FilterChip(kind: .bestShots)) }
        result += labels.map { FilterChip(kind: .label($0)) }
        if let freeText { result.append(FilterChip(kind: .freeText(freeText))) }
        return result
    }

    public func removing(_ chip: FilterChip) -> QueryFilters {
        var copy = self
        switch chip.kind {
        case .colour(let f): copy.colours.removeAll { $0 == f }
        case .people: copy.people = nil
        case .faces: copy.faces = nil
        case .text: copy.text = nil
        case .orientation: copy.orientation = nil
        case .label(let l): copy.labels.removeAll { $0 == l }
        case .freeText: copy.freeText = nil
        case .look(let l): copy.looks.removeAll { $0 == l }
        case .style(let t): copy.styles.removeAll { $0 == t }
        case .textQuery: copy.textQuery = nil
        case .utility: copy.utility = nil
        case .bestShots: copy.bestShots = false
        case .similar: copy.similarTo = nil
        }
        return copy
    }

    /// A readable one-line description, for debug output and default saved-look names.
    public var summary: String {
        chips.map(\.title).joined(separator: " · ")
    }
}
