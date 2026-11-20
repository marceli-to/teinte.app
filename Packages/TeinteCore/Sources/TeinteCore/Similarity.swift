import Foundation

/// The image a "Find similar" search starts from.
public struct SimilarSeed: Codable, Hashable, Sendable {
    public var id: UUID
    /// For the chip ("like IMG_2041.jpg"), so it reads right even if the image is gone.
    public var fileName: String

    public init(id: UUID, fileName: String) { self.id = id; self.fileName = fileName }
}

/// How close two palettes are, 0…1 (1 = the same colours in the same amounts).
///
/// A Gaussian kernel over OKLab distance between every pair of palette colours, weighted by
/// their shares and normalised like a cosine: K(a, b) / √(K(a, a) · K(b, b)). Two near colours
/// count as partly the same, so a terracotta and a brick red palette are close, unlike with buckets.
public enum PaletteSimilarity {
    /// OKLab distance at which two colours count as about 60 % the same.
    /// 0.08 ≈ a clearly visible but related shift (brick → terracotta, sky blue → slate).
    public static let sigma: Float = 0.08

    public static func similarity(_ a: [PaletteEntry], _ b: [PaletteEntry]) -> Float {
        let ab = kernel(a, b), aa = kernel(a, a), bb = kernel(b, b)
        guard aa > 0, bb > 0 else { return 0 }
        return min(ab / (aa * bb).squareRoot(), 1)
    }

    /// Self-kernel, cached per row when ranking a whole library.
    public static func kernel(_ a: [PaletteEntry], _ b: [PaletteEntry]) -> Float {
        let k = -1 / (2 * sigma * sigma)
        var sum: Float = 0
        for x in a {
            for y in b {
                let dl = x.colour.l - y.colour.l, da = x.colour.a - y.colour.a, db = x.colour.b - y.colour.b
                sum += x.share * y.share * expf((dl * dl + da * da + db * db) * k)
            }
        }
        return sum
    }
}

/// "Find similar": ranks by what's in the image (embedding cosine with the seed) blended with its
/// colours (palette similarity), plus the text query if there is one.
///
/// Each signal is turned into a z-score over the whole library first, so they add up on the same
/// scale regardless of the model (image–image cosines sit around 0.4–0.95, text–image around 0–0.2).
public struct SimilarityRanking: Hashable, Sendable {
    public var imageWeight: Float
    public var colourWeight: Float
    /// Weight of the text query, when there is one.
    public var textWeight: Float
    /// Combined z-score where the match is 50 %, and its width.
    public var zMidpoint: Float
    public var zWidth: Float

    public init(imageWeight: Float, colourWeight: Float, textWeight: Float, zMidpoint: Float, zWidth: Float) {
        self.imageWeight = imageWeight; self.colourWeight = colourWeight; self.textWeight = textWeight
        self.zMidpoint = zMidpoint; self.zWidth = zWidth
    }

    public static let `default` = SimilarityRanking(
        imageWeight: 0.65, colourWeight: 0.35, textWeight: 0.5, zMidpoint: 2.0, zWidth: 0.5)

    /// Per-row scores for every row of `snapshot` (seed included). Rows without an embedding get
    /// the image term as the library mean (z = 0), so they can still surface on colour.
    public func scores(seedRow: Int, in snapshot: IndexSnapshot, textVector: [Float]?) -> [Float] {
        let rows = snapshot.rows
        let embedded = rows.indices.filter { rows[$0].embedding != nil }
        var combined = [Float](repeating: 0, count: rows.count)

        func add(_ values: [Float], over population: [Int], weight: Float) {
            let stats = MatchCalibration.LibraryStats(population.lazy.map { values[$0] })
            guard stats.deviation > 1e-6 else { return }
            for i in population { combined[i] += weight * (values[i] - stats.mean) / stats.deviation }
        }

        if let seed = rows[seedRow].embedding, seed.count == snapshot.dimension {
            add(snapshot.scores(for: seed), over: embedded, weight: imageWeight)
        }
        let seedPalette = rows[seedRow].palette
        if !seedPalette.isEmpty {
            let seedSelf = PaletteSimilarity.kernel(seedPalette, seedPalette)
            let colour = rows.map { r -> Float in
                guard !r.palette.isEmpty, seedSelf > 0 else { return 0 }
                let own = PaletteSimilarity.kernel(r.palette, r.palette)
                guard own > 0 else { return 0 }
                return PaletteSimilarity.kernel(seedPalette, r.palette) / (seedSelf * own).squareRoot()
            }
            add(colour, over: Array(rows.indices), weight: colourWeight)
        }
        if let t = textVector, t.count == snapshot.dimension {
            add(snapshot.scores(for: t), over: embedded, weight: textWeight)
        }
        return combined
    }

    /// Calibrated match for a combined score, judged against the rest of the library.
    public func match(score: Float, library: MatchCalibration.LibraryStats) -> Float {
        guard library.deviation > 1e-6 else { return 0 }
        let z = (score - library.mean) / library.deviation
        return 1 / (1 + expf(-(z - zMidpoint) / max(zWidth, 1e-3)))
    }
}

extension Ranker {
    /// Rank `candidates` by similarity to the image in `seedRow`. The seed itself is left out.
    public static func rankSimilar(
        candidates: [Int], in snapshot: IndexSnapshot, seedRow: Int, textVector: [Float]?,
        ranking: SimilarityRanking = .default
    ) -> [RankedResult] {
        let scores = ranking.scores(seedRow: seedRow, in: snapshot, textVector: textVector)
        let library = MatchCalibration.LibraryStats(snapshot.rows.indices.lazy.filter { $0 != seedRow }.map { scores[$0] })
        var results = candidates.filter { $0 != seedRow }.map { row in
            RankedResult(row: row, score: scores[row], match: ranking.match(score: scores[row], library: library))
        }
        results.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return snapshot.rows[a.row].fileName.localizedStandardCompare(snapshot.rows[b.row].fileName) == .orderedAscending
        }
        return results
    }
}
