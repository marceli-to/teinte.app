import Foundation
import TeinteCore

/// Owns the in-memory index and the on-disk embeddings. Queries run here, off the main actor.
actor SearchIndex {
    private(set) var snapshot: IndexSnapshot
    private let embeddings: EmbeddingStore?

    init(dimension: Int, embeddings: EmbeddingStore?) {
        self.snapshot = IndexSnapshot(dimension: dimension)
        self.embeddings = embeddings
    }

    var count: Int { snapshot.count }

    /// Build from the database at launch. Returns the IDs that need re-embedding (e.g. after a model change).
    func load(_ features: [ImageFeatures]) -> [UUID] {
        let vectors = (try? embeddings?.loadAll()) ?? [:]
        var missing: [UUID] = []
        var s = IndexSnapshot(dimension: snapshot.dimension)
        for var f in features {
            f.embedding = vectors[f.id]
            if f.embedding == nil, embeddings != nil { missing.append(f.id) }
            s.upsert(f)
        }
        snapshot = s
        if let embeddings, embeddings.deadFraction > 0.1 { try? embeddings.compact() }
        return missing
    }

    func upsert(_ features: [ImageFeatures]) {
        var toStore: [(UUID, [Float])] = []
        for f in features {
            snapshot.upsert(f)
            if let e = f.embedding { toStore.append((f.id, e)) }
        }
        try? embeddings?.putMany(toStore)
    }

    func remove(_ ids: [UUID]) {
        for id in ids {
            snapshot.remove(id: id)
            try? embeddings?.remove(id)
        }
    }

    /// A file was renamed or moved: same analysis and embedding, new name.
    func rename(_ renames: [(UUID, String)]) {
        for (id, name) in renames {
            guard let row = snapshot.row(for: id) else { continue }
            var f = snapshot.rows[row]
            f.fileName = name
            snapshot.upsert(f)
        }
    }

    func setAvailability(folderID: UUID, available: Bool) {
        snapshot.setAvailability(folderID: folderID, available: available)
    }

    struct Hit: Sendable, Identifiable, Hashable {
        var id: UUID
        var features: ImageFeatures
        var score: Float
        var match: Float?
    }

    struct Outcome: Sendable {
        var hits: [Hit]
        var total: Int
        var filteredCount: Int
        var milliseconds: Double
    }

    func search(_ query: ResolvedQuery, vector: [Float]?, labelVectors: [[Float]]? = nil,
                styleVectors: [[Float]]? = nil, scope: SearchScope, calibration: MatchCalibration) -> Outcome {
        let start = DispatchTime.now()
        let labelScores = labelVectors?.filter { $0.count == snapshot.dimension }.map { snapshot.scores(for: $0) }
        let styleScores = styleVectors?.filter { $0.count == snapshot.dimension }.map { snapshot.scores(for: $0) }
        let candidates = FilterEngine.candidates(
            in: snapshot, query: query, scope: scope,
            labelScores: labelScores?.count == query.hardLabels.count ? labelScores : nil,
            styleScores: styleScores?.count == query.filters.styles.count ? styleScores : nil,
            calibration: calibration)
        // "Find similar": the seed image (if it's still in the library) drives the order; the text, if any, adds to it.
        let ranked: [RankedResult]
        if let seed = query.filters.similarTo, let seedRow = snapshot.row(for: seed.id) {
            ranked = Ranker.rankSimilar(candidates: candidates, in: snapshot, seedRow: seedRow, textVector: vector)
        } else {
            ranked = Ranker.rank(candidates: candidates, in: snapshot, queryVector: vector,
                                 filters: query.filters, calibration: calibration)
        }
        let hits = ranked.map { r in
            Hit(id: snapshot.rows[r.row].id, features: snapshot.rows[r.row], score: r.score, match: r.match)
        }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        return Outcome(hits: hits, total: snapshot.count, filteredCount: candidates.count, milliseconds: ms)
    }

    /// True when the free text is a word some image shows ("ellesse"), so it should filter, not just rank.
    func shouldPromoteToTextQuery(_ freeText: String) -> Bool {
        FilterEngine.shouldPromoteToTextQuery(freeText, in: snapshot)
    }

    func features(for id: UUID) -> ImageFeatures? {
        snapshot.row(for: id).map { snapshot.rows[$0] }
    }

    /// The style tags that apply to one image, judged against the library exactly as the filter does.
    func styleTags(for id: UUID, prompts: [(StyleTag, [Float])], calibration: MatchCalibration) -> [StyleTag] {
        guard let row = snapshot.row(for: id), snapshot.rows[row].embedding != nil else { return [] }
        let s = snapshot
        return prompts.compactMap { tag, vector in
            guard vector.count == s.dimension else { return nil }
            let scores = s.scores(for: vector)
            let library = MatchCalibration.LibraryStats(
                s.rows.indices.lazy.filter { s.rows[$0].embedding != nil }.map { scores[$0] })
            return calibration.match(cosine: scores[row], library: library) >= FilterEngine.styleMatchThreshold ? tag : nil
        }
    }

    func embedding(for id: UUID) -> [Float]? {
        snapshot.row(for: id).flatMap { snapshot.rows[$0].embedding }
    }
}

extension SearchIndex {
    struct Stats: Sendable, Equatable {
        var total = 0
        var recent = 0
        var perFolder: [UUID: Int] = [:]
        var band: [OKLab] = []
    }

    /// Sidebar counts and the colour band. Only available images count.
    func stats(recentSince: Date) -> Stats {
        var s = Stats()
        var palettes: [[PaletteEntry]] = []
        for row in snapshot.rows where row.available {
            s.total += 1
            if row.addedAt >= recentSince { s.recent += 1 }
            s.perFolder[row.folderID, default: 0] += 1
            palettes.append(row.palette)
        }
        s.band = ColourBand.swatches(from: palettes)
        return s
    }
}
