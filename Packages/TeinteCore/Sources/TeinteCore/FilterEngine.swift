import Foundation

/// A query with its labels split into hard filters (known to Vision) and soft ones (sent to embedding search).
public struct ResolvedQuery: Hashable, Sendable {
    public var filters: QueryFilters
    /// Vision identifiers the image must carry.
    public var hardLabels: [String]
    /// Labels that didn't resolve; they're appended to the ranking text.
    public var softLabels: [String]

    /// Text used for embedding ranking: free text plus unresolved labels. Nil if there's nothing.
    public var rankingText: String? {
        let parts = [filters.freeText].compactMap { $0 } + softLabels
        let joined = parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return joined.isEmpty ? nil : joined
    }

    public init(filters: QueryFilters, resolver: LabelResolver) {
        self.filters = filters
        var hard: [String] = [], soft: [String] = []
        for label in filters.labels {
            if let id = resolver.resolve(label) { hard.append(id) } else { soft.append(label) }
        }
        hardLabels = hard
        softLabels = soft
    }
}

/// Applies the cheap, exact filters.
public enum FilterEngine {
    public static func candidates(
        in snapshot: IndexSnapshot, query: ResolvedQuery, scope: SearchScope = .all
    ) -> [Int] {
        let f = query.filters
        var result: [Int] = []
        result.reserveCapacity(snapshot.count)
        for (i, row) in snapshot.rows.enumerated() {
            guard row.available else { continue }
            switch scope {
            case .all: break
            case .addedSince(let date): if row.addedAt < date { continue }
            case .folder(let id): if row.folderID != id { continue }
            }
            if matches(row, filters: f, hardLabels: query.hardLabels) { result.append(i) }
        }
        return result
    }

    public static func matches(_ row: ImageFeatures, filters f: QueryFilters, hardLabels: [String]) -> Bool {
        for c in f.colours where !c.mode.matches(share: row.share(of: c.bucket)) { return false }
        if let people = f.people, !people.matches(count: row.personCount) { return false }
        if let faces = f.faces, !faces.matches(row.faceCount > 0) { return false }
        if let text = f.text, !text.matches(row.hasText) { return false }
        if let o = f.orientation, row.orientation != o { return false }
        for label in hardLabels where !row.labels.contains(label) { return false }
        return true
    }
}
