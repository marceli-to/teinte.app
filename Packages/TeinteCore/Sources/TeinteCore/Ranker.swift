import Foundation

public struct RankedResult: Hashable, Sendable {
    public var row: Int
    /// Raw cosine similarity (or a filter-strength value when there's no ranking vector).
    public var score: Float
    /// Calibrated match, 0…1. Nil when the order comes from filters only.
    public var match: Float?
}

/// Turns a raw cosine similarity into a match percentage.
///
/// Two checks, multiplied, so a result needs both to score high:
/// - **Relative:** how far the image stands out from the rest of the library for the same query
///   (z-score over every embedded image). Full sentences score lower than single words, so absolute
///   cosines alone don't compare well across queries.
/// - **Absolute:** a floor on the cosine itself, so a query with no real match ("a unicorn")
///   doesn't show its least-bad images as 90 %.
///
/// Tuned on a 993-image library with SigLIP base: real matches land at 85–99 %, the tail of a good
/// query at 50–70 %, the best of a query with no match at ~30 %. Retune when the model changes.
public struct MatchCalibration: Hashable, Sendable, Codable {
    /// Cosine where the absolute check is 50 %.
    public var midpoint: Float
    /// Cosine distance from `midpoint` per logit unit (smaller = steeper).
    public var width: Float
    /// Z-score where the relative check is 50 %.
    public var zMidpoint: Float
    public var zWidth: Float
    /// Below this many embedded images the library stats are noise; only the absolute check applies.
    public var minLibrary: Int

    public init(midpoint: Float, width: Float, zMidpoint: Float, zWidth: Float, minLibrary: Int = 30) {
        self.midpoint = midpoint; self.width = width
        self.zMidpoint = zMidpoint; self.zWidth = zWidth; self.minLibrary = minLibrary
    }

    public static let generic = MatchCalibration(midpoint: 0.045, width: 0.012, zMidpoint: 2.0, zWidth: 0.6)

    /// Mean and standard deviation of the query's cosines over the library.
    public struct LibraryStats: Hashable, Sendable {
        public var mean: Float
        public var deviation: Float
        public var count: Int

        public init(mean: Float, deviation: Float, count: Int) {
            self.mean = mean; self.deviation = deviation; self.count = count
        }

        public init(_ cosines: some Sequence<Float>) {
            var n = 0, sum: Double = 0, squares: Double = 0
            for c in cosines { n += 1; sum += Double(c); squares += Double(c) * Double(c) }
            let mean = n > 0 ? sum / Double(n) : 0
            let variance = n > 0 ? max(squares / Double(n) - mean * mean, 0) : 0
            self.init(mean: Float(mean), deviation: Float(variance.squareRoot()), count: n)
        }
    }

    public func match(cosine: Float, library: LibraryStats?) -> Float {
        let absolute = Self.sigmoid((cosine - midpoint) / max(width, 1e-4))
        guard let library, library.count >= minLibrary, library.deviation > 1e-6 else { return absolute }
        let z = (cosine - library.mean) / library.deviation
        return absolute * Self.sigmoid((z - zMidpoint) / max(zWidth, 1e-3))
    }

    private static func sigmoid(_ x: Float) -> Float { 1 / (1 + expf(-x)) }
}

public enum Ranker {
    /// Weight of the colour-share boost when the query asks for a `mostly` colour.
    /// Small on purpose: it reorders near-ties, it doesn't override the embedding.
    public static let colourBoostWeight: Float = 0.02

    /// Rank `candidates` (row indices into `snapshot`).
    ///
    /// - With a query vector: by cosine (+ colour boost), match % from `calibration`.
    /// - Without: by filter strength (share of the requested colours), then newest first; match is nil.
    public static func rank(
        candidates: [Int], in snapshot: IndexSnapshot, queryVector: [Float]?,
        filters: QueryFilters, calibration: MatchCalibration = .generic
    ) -> [RankedResult] {
        let boostBuckets = filters.colours.filter { $0.mode != .without }.map(\.bucket)

        func colourStrength(_ row: Int) -> Float {
            guard !boostBuckets.isEmpty else { return 0 }
            let r = snapshot.rows[row]
            return boostBuckets.reduce(0) { $0 + r.share(of: $1) } / Float(boostBuckets.count)
        }

        if let q = queryVector, q.count == snapshot.dimension {
            let all = snapshot.scores(for: q)
            let mostly = filters.colours.contains { $0.mode == .mostly }
            // Stats over the whole library, not just the candidates: "how good is this for the query".
            let library = MatchCalibration.LibraryStats(
                snapshot.rows.indices.lazy.filter { snapshot.rows[$0].embedding != nil }.map { all[$0] })
            var results = candidates.map { row -> RankedResult in
                let cos = all[row]
                let hasEmbedding = snapshot.rows[row].embedding != nil
                let boosted = cos + (mostly ? colourBoostWeight * colourStrength(row) : 0)
                return RankedResult(
                    row: row, score: hasEmbedding ? boosted : -1,
                    match: hasEmbedding ? calibration.match(cosine: cos, library: library) : nil)
            }
            results.sort { a, b in
                a.score != b.score ? a.score > b.score : tieBreak(a.row, b.row, snapshot)
            }
            return results
        }

        var results = candidates.map { RankedResult(row: $0, score: colourStrength($0), match: nil) }
        results.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            let da = snapshot.rows[a.row].addedAt, db = snapshot.rows[b.row].addedAt
            return da != db ? da > db : tieBreak(a.row, b.row, snapshot)
        }
        return results
    }

    private static func tieBreak(_ a: Int, _ b: Int, _ s: IndexSnapshot) -> Bool {
        s.rows[a].fileName.localizedStandardCompare(s.rows[b].fileName) == .orderedAscending
    }
}
