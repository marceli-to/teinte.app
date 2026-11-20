import Foundation

public struct RankedResult: Hashable, Sendable {
    public var row: Int
    /// Raw cosine similarity (or a filter-strength value when there's no ranking vector).
    public var score: Float
    /// Calibrated match, 0…1. Nil when the order comes from filters only.
    public var match: Float?
}

/// Turns raw cosine similarities into a match percentage.
///
/// SigLIP is trained with a sigmoid loss: p = σ(scale · cos + bias), with learned scale/bias.
/// Those are the defaults; `offset` and `temperature` are the knobs tuned on real libraries in Phase 1.
public struct MatchCalibration: Hashable, Sendable, Codable {
    public var scale: Float
    public var bias: Float
    /// Added to the logit. Retrieval queries score lower than the training captions, so this lifts them.
    public var offset: Float
    /// Divides the logit; >1 flattens the curve.
    public var temperature: Float

    public init(scale: Float, bias: Float, offset: Float = 0, temperature: Float = 1) {
        self.scale = scale; self.bias = bias; self.offset = offset; self.temperature = temperature
    }

    /// Fallback when model metadata is missing: maps cos 0.05 → ~12 %, 0.15 → ~88 %.
    public static let generic = MatchCalibration(scale: 40, bias: -4)

    public func match(cosine: Float) -> Float {
        let logit = (scale * cosine + bias + offset) / max(temperature, 0.01)
        return 1 / (1 + expf(-logit))
    }
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
            var results = candidates.map { row -> RankedResult in
                let cos = all[row]
                let hasEmbedding = snapshot.rows[row].embedding != nil
                let boosted = cos + (mostly ? colourBoostWeight * colourStrength(row) : 0)
                return RankedResult(
                    row: row, score: hasEmbedding ? boosted : -1,
                    match: hasEmbedding ? calibration.match(cosine: cos) : nil)
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
