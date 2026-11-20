import Foundation
import Testing
@testable import TeinteCore

@Suite("Ranking order")
struct RankingTests {
    /// Hand-built 3-D "embeddings": axis 0 = beach, axis 1 = city, axis 2 = forest.
    static func snapshot() -> IndexSnapshot {
        var s = IndexSnapshot(dimension: 3)
        let rows: [(String, [Float], Float)] = [
            ("beach.jpg", [0.9, 0.1, 0.0], 0.5),
            ("city.jpg", [0.1, 0.9, 0.1], 0.6),
            ("forest.jpg", [0.0, 0.2, 0.9], 0.1),
            ("beach_city.jpg", [0.6, 0.6, 0.0], 0.8),
        ]
        for (name, e, blue) in rows {
            var shares = ColourProfile.empty.bucketShares
            shares[ColourBucket.blue.index] = blue
            s.upsert(ImageFeatures(fileName: name, bucketShares: shares, embedding: l2Normalized(e)))
        }
        return s
    }

    @Test func ordersByCosine() {
        let s = Self.snapshot()
        let ranked = Ranker.rank(candidates: Array(0..<s.count), in: s, queryVector: l2Normalized([1, 0, 0]), filters: .empty)
        #expect(ranked.map { s.rows[$0.row].fileName } == ["beach.jpg", "beach_city.jpg", "city.jpg", "forest.jpg"])
        #expect(ranked.allSatisfy { $0.match != nil })
        #expect(ranked.map(\.match!) == ranked.map(\.match!).sorted(by: >))
    }

    @Test func onlyCandidatesAreRanked() {
        let s = Self.snapshot()
        let ranked = Ranker.rank(candidates: [1, 2], in: s, queryVector: l2Normalized([0, 0, 1]), filters: .empty)
        #expect(ranked.map(\.row) == [2, 1])
    }

    @Test func colourShareBreaksTies() {
        var s = IndexSnapshot(dimension: 2)
        for (name, blue) in [("a.jpg", Float(0.41)), ("b.jpg", 0.85)] {
            var shares = ColourProfile.empty.bucketShares
            shares[ColourBucket.blue.index] = blue
            s.upsert(ImageFeatures(fileName: name, bucketShares: shares, embedding: l2Normalized([1, 1])))
        }
        let f = QueryFilters(colours: [.init(.blue, .mostly)])
        let ranked = Ranker.rank(candidates: [0, 1], in: s, queryVector: l2Normalized([1, 0.5]), filters: f)
        #expect(ranked.map { s.rows[$0.row].fileName } == ["b.jpg", "a.jpg"])
    }

    @Test func withoutQueryVectorSortsByFilterStrength() {
        let s = Self.snapshot()
        let f = QueryFilters(colours: [.init(.blue, .contains)])
        let ranked = Ranker.rank(candidates: Array(0..<s.count), in: s, queryVector: nil, filters: f)
        #expect(ranked.map { s.rows[$0.row].fileName } == ["beach_city.jpg", "city.jpg", "beach.jpg", "forest.jpg"])
        #expect(ranked.allSatisfy { $0.match == nil })
    }

    @Test func imagesWithoutEmbeddingSinkToTheEnd() {
        var s = Self.snapshot()
        s.upsert(ImageFeatures(fileName: "pending.jpg"))
        let ranked = Ranker.rank(candidates: Array(0..<s.count), in: s, queryVector: l2Normalized([0, 0, 1]), filters: .empty)
        #expect(s.rows[ranked.last!.row].fileName == "pending.jpg")
        #expect(ranked.last!.match == nil)
    }

    @Test func calibrationIsMonotonic() {
        let cal = MatchCalibration.generic
        let lib = MatchCalibration.LibraryStats(mean: -0.02, deviation: 0.03, count: 1000)
        for stats in [lib, nil] {
            let values = stride(from: Float(-0.2), through: 0.4, by: 0.01).map { cal.match(cosine: $0, library: stats) }
            #expect(values == values.sorted())
            #expect(values.first! < 0.01 && values.last! > 0.99)
        }
    }

    /// Numbers from the real library (SigLIP base, 993 images).
    @Test func calibrationSeparatesRealMatchesFromNone() {
        let cal = MatchCalibration.generic
        let dog = MatchCalibration.LibraryStats(mean: -0.0159, deviation: 0.0165, count: 993)
        let unicorn = MatchCalibration.LibraryStats(mean: -0.0161, deviation: 0.0170, count: 993)
        let mountains = MatchCalibration.LibraryStats(mean: -0.0086, deviation: 0.0370, count: 993)
        #expect(cal.match(cosine: 0.0841, library: dog) > 0.9)       // best dog
        #expect(cal.match(cosine: 0.1277, library: mountains) > 0.8) // best snowy mountain
        #expect(cal.match(cosine: 0.0397, library: unicorn) < 0.4)   // no unicorns in the library
    }

    @Test func smallLibraryUsesAbsoluteOnly() {
        let cal = MatchCalibration.generic
        let tiny = MatchCalibration.LibraryStats(mean: 0, deviation: 0.03, count: 5)
        #expect(cal.match(cosine: 0.09, library: tiny) == cal.match(cosine: 0.09, library: nil))
    }

    @Test func scoresMatchManualDotProducts() {
        let s = Self.snapshot()
        let q = l2Normalized([0.3, 0.5, 0.2])
        let fast = s.scores(for: q)
        for (i, row) in s.rows.enumerated() {
            let manual = zip(row.embedding!, q).map(*).reduce(0, +)
            #expect(abs(fast[i] - manual) < 1e-5)
        }
    }
}

@Suite("Embedding store")
struct EmbeddingStoreTests {
    func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("teinte-test-\(UUID().uuidString)/embeddings.bin")
    }

    @Test func roundTripTombstoneAndCompact() throws {
        let url = tempURL()
        let a = UUID(), b = UUID(), c = UUID()
        do {
            let store = try EmbeddingStore(url: url, dimension: 4, modelID: "test-model")
            try store.putMany([(a, [1, 0, 0, 0]), (b, [0, 1, 0, 0]), (c, [0, 0, 0.5, 0.25])])
            try store.remove(b)
            try store.put(a, [0, 0, 0, 1]) // replace
        }
        // Reopen from disk.
        let store = try EmbeddingStore(url: url, dimension: 4, modelID: "test-model")
        #expect(!store.wasReset)
        var all = try store.loadAll()
        #expect(Set(all.keys) == [a, c])
        #expect(all[a] == [0, 0, 0, 1])
        #expect(all[c] == [0, 0, 0.5, 0.25])
        #expect(store.deadFraction == 0.5) // b, and the old a

        try store.compact()
        #expect(store.deadFraction == 0)
        all = try store.loadAll()
        #expect(Set(all.keys) == [a, c])
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int
        #expect(size == EmbeddingStore.headerSize + 2 * (16 + 4 * 2))
    }

    @Test func differentModelResets() throws {
        let url = tempURL()
        try EmbeddingStore(url: url, dimension: 4, modelID: "old").put(UUID(), [1, 2, 3, 4])
        let store = try EmbeddingStore(url: url, dimension: 4, modelID: "new")
        #expect(store.wasReset)
        #expect(store.count == 0)
    }
}
