import Foundation

/// A query with its labels split into hard filters (known to Vision) and soft ones (sent to embedding search).
public struct ResolvedQuery: Hashable, Sendable {
    public var filters: QueryFilters
    /// Vision identifiers the image must carry.
    public var hardLabels: [String]
    /// Labels that didn't resolve; they're appended to the ranking text.
    public var softLabels: [String]
    /// Per hard label: the Vision identifiers that satisfy it (the label plus its related group).
    public var labelGroups: [[String]]

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
            if let id = resolver.resolve(label) {
                if !hard.contains(id) { hard.append(id) }
            } else {
                soft.append(label)
            }
        }
        hardLabels = hard
        softLabels = soft
        labelGroups = hard.map { resolver.group(for: $0) }
    }

    /// The text used to check a hard label with the embedding model: "a photo of a building".
    public static func labelPrompt(_ identifier: String) -> String {
        let name = LabelResolver.displayName(identifier == "house_single" ? "house" : identifier)
        let article = name.first.map { "aeiou".contains($0) } == true ? "an" : "a"
        return "a photo of \(article) \(name)"
    }
}

/// Applies the cheap, exact filters.
///
/// A label passes when Vision tagged the image with it (or a related identifier), or when the
/// embedding model sees it: the image's cosine with `labelPrompt` is at least `semanticLabelThreshold`.
/// Vision alone misses too much ("building" is often only "structure"), so it can't be a hard filter on its own.
public enum FilterEngine {
    /// Tuned on a 993-image library: above ≈0.055 the matches for "a photo of a building",
    /// "a dog", "a boat" are nearly all right; below ≈0.045 they turn to noise.
    public static let semanticLabelThreshold: Float = 0.055

    /// - Parameter labelScores: per hard label (same order as `query.hardLabels`), the cosine of every
    ///   row with that label's prompt. Nil when there's no embedding model: then Vision decides alone.
    public static func candidates(
        in snapshot: IndexSnapshot, query: ResolvedQuery, scope: SearchScope = .all,
        labelScores: [[Float]]? = nil
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
            guard matches(row, filters: f, hardLabels: []) else { continue }
            let labelsOK = query.labelGroups.indices.allSatisfy { k in
                if query.labelGroups[k].contains(where: row.labels.contains) { return true }
                guard let scores = labelScores, scores.indices.contains(k), scores[k].indices.contains(i),
                      row.embedding != nil else { return false }
                return scores[k][i] >= semanticLabelThreshold
            }
            if labelsOK { result.append(i) }
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
