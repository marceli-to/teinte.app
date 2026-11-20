import Foundation

public enum ColourMode: String, Codable, Hashable, Sendable, CaseIterable {
    /// share ≥ 0.40
    case mostly
    /// share ≥ 0.10
    case contains
    /// share < 0.05
    case without

    public static let mostlyThreshold: Float = 0.40
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

public struct ColourFilter: Codable, Hashable, Sendable {
    public var bucket: ColourBucket
    public var mode: ColourMode

    public init(_ bucket: ColourBucket, _ mode: ColourMode) {
        self.bucket = bucket; self.mode = mode
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

    public init(
        colours: [ColourFilter] = [], people: PeopleFilter? = nil, faces: Presence? = nil,
        text: Presence? = nil, orientation: Orientation? = nil, labels: [String] = [], freeText: String? = nil
    ) {
        self.colours = colours; self.people = people; self.faces = faces; self.text = text
        self.orientation = orientation; self.labels = labels; self.freeText = freeText
    }

    public static let empty = QueryFilters()

    public var hasStructuredFilters: Bool {
        !colours.isEmpty || people != nil || faces != nil || text != nil || orientation != nil || !labels.isEmpty
    }

    public var isEmpty: Bool { !hasStructuredFilters && (freeText?.isEmpty ?? true) }

    /// Normalises the parser output: dedupes colours (last one wins per bucket), lowercases labels, trims free text.
    public func normalized() -> QueryFilters {
        var copy = self
        var seen = Set<ColourBucket>()
        copy.colours = colours.reversed().filter { seen.insert($0.bucket).inserted }.reversed()
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
    }

    public var kind: Kind
    public var id: Kind { kind }

    public var title: String {
        switch kind {
        case .colour(let f):
            switch f.mode {
            case .mostly: "mostly \(f.bucket.rawValue)"
            case .contains: "some \(f.bucket.rawValue)"
            case .without: "no \(f.bucket.rawValue)"
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
        }
    }
}

extension QueryFilters {
    public var chips: [FilterChip] {
        var result: [FilterChip] = colours.map { FilterChip(kind: .colour($0)) }
        if let people { result.append(FilterChip(kind: .people(people))) }
        if let faces { result.append(FilterChip(kind: .faces(faces))) }
        if let text { result.append(FilterChip(kind: .text(text))) }
        if let orientation { result.append(FilterChip(kind: .orientation(orientation))) }
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
        }
        return copy
    }

    /// A readable one-line description, for debug output and default saved-look names.
    public var summary: String {
        chips.map(\.title).joined(separator: " · ")
    }
}
