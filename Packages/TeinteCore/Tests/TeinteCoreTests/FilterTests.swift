import Foundation
import Testing
@testable import TeinteCore

@Suite("Filter application")
struct FilterTests {
    static func shares(_ pairs: [ColourBucket: Float]) -> [Float] {
        var s = ColourProfile.empty.bucketShares
        for (b, v) in pairs { s[b.index] = v }
        return s
    }

    static func image(blue: Float = 0, people: Int = 0, faces: Int = 0, text: Bool = false,
                      w: Int = 400, h: Int = 300, labels: [String] = [], folder: UUID = UUID(),
                      added: Date = .now, available: Bool = true) -> ImageFeatures {
        ImageFeatures(folderID: folder, fileName: "x.jpg", addedAt: added, pixelWidth: w, pixelHeight: h,
                      bucketShares: shares([.blue: blue, .white: 1 - blue]), personCount: people,
                      faceCount: faces, hasText: text, labels: labels, available: available)
    }

    func run(_ images: [ImageFeatures], _ filters: QueryFilters, scope: SearchScope = .all,
             vocabulary: [String] = []) -> [Int] {
        var snapshot = IndexSnapshot(dimension: 4)
        images.forEach { snapshot.upsert($0) }
        let q = ResolvedQuery(filters: filters, resolver: LabelResolver(vocabulary: vocabulary))
        return FilterEngine.candidates(in: snapshot, query: q, scope: scope)
    }

    @Test("mostly: share ≥ 0.33", arguments: [(Float(0.32), false), (0.33, true), (0.9, true)])
    func mostly(share: Float, passes: Bool) {
        #expect(ColourMode.mostly.matches(share: share) == passes)
        #expect(run([Self.image(blue: share)], QueryFilters(colours: [.init(.blue, .mostly)])).count == (passes ? 1 : 0))
    }

    @Test("contains: share ≥ 0.10", arguments: [(Float(0.09), false), (0.10, true), (0.5, true)])
    func contains(share: Float, passes: Bool) {
        #expect(ColourMode.contains.matches(share: share) == passes)
    }

    @Test("without: share < 0.05", arguments: [(Float(0.0), true), (0.049, true), (0.05, false), (0.3, false)])
    func without(share: Float, passes: Bool) {
        #expect(ColourMode.without.matches(share: share) == passes)
        #expect(run([Self.image(blue: share)], QueryFilters(colours: [.init(.blue, .without)])).count == (passes ? 1 : 0))
    }

    @Test func people() {
        let imgs = (0...5).map { Self.image(people: $0) }
        #expect(run(imgs, QueryFilters(people: .any)) == [1, 2, 3, 4, 5])
        #expect(run(imgs, QueryFilters(people: PeopleFilter.none)) == [0])
        #expect(run(imgs, QueryFilters(people: .exactly(2))) == [2])
        #expect(run(imgs, QueryFilters(people: .atLeast(3))) == [3, 4, 5])
    }

    @Test func facesTextOrientation() {
        let imgs = [
            Self.image(faces: 1, text: false, w: 400, h: 300),  // landscape
            Self.image(faces: 0, text: true, w: 300, h: 400),   // portrait
            Self.image(faces: 2, text: true, w: 500, h: 510),   // square (±5 %)
        ]
        #expect(run(imgs, QueryFilters(faces: .with)) == [0, 2])
        #expect(run(imgs, QueryFilters(faces: .without)) == [1])
        #expect(run(imgs, QueryFilters(text: .with)) == [1, 2])
        #expect(run(imgs, QueryFilters(text: .without)) == [0])
        #expect(run(imgs, QueryFilters(orientation: .landscape)) == [0])
        #expect(run(imgs, QueryFilters(orientation: .portrait)) == [1])
        #expect(run(imgs, QueryFilters(orientation: .square)) == [2])
    }

    @Test func combinedWithAnd() {
        let imgs = [
            Self.image(blue: 0.7, people: 2),
            Self.image(blue: 0.7, people: 0),
            Self.image(blue: 0.2, people: 2),
        ]
        let f = QueryFilters(colours: [.init(.blue, .mostly)], people: .any)
        #expect(run(imgs, f) == [0])
    }

    @Test func labelsResolveOrBecomeSoft() {
        let imgs = [Self.image(labels: ["dog", "animal"]), Self.image(labels: ["cat", "animal"])]
        let vocab = ["dog", "cat", "animal"]
        #expect(run(imgs, QueryFilters(labels: ["dogs"]), vocabulary: vocab) == [0])
        // Unknown label: no hard filter, goes to ranking text instead.
        #expect(run(imgs, QueryFilters(labels: ["jetty"]), vocabulary: vocab) == [0, 1])
        let q = ResolvedQuery(filters: QueryFilters(labels: ["jetty"], freeText: "sunset"), resolver: LabelResolver(vocabulary: vocab))
        #expect(q.hardLabels.isEmpty)
        #expect(q.rankingText == "sunset jetty")
    }

    @Test func relatedLabelsSatisfyAGroup() {
        // Vision tags a brick facade "structure" + "apartment", never "building".
        let imgs = [Self.image(labels: ["structure", "apartment"]), Self.image(labels: ["structure", "table"])]
        let vocab = ["building", "apartment", "structure", "table"]
        #expect(run(imgs, QueryFilters(labels: ["building"]), vocabulary: vocab) == [0])
        #expect(run(imgs, QueryFilters(labels: ["architecture"]), vocabulary: vocab) == [0])
    }

    @Test func embeddingRescuesAMissedLabel() {
        var snapshot = IndexSnapshot(dimension: 4)
        var seen = Self.image(labels: ["structure"]); seen.embedding = [1, 0, 0, 0]
        var missed = Self.image(labels: ["structure"]); missed.embedding = [0, 1, 0, 0]
        let noEmbedding = Self.image(labels: ["structure"])
        [seen, missed, noEmbedding].forEach { snapshot.upsert($0) }
        let q = ResolvedQuery(filters: QueryFilters(labels: ["building"]), resolver: LabelResolver(vocabulary: ["building"]))
        let t = FilterEngine.semanticLabelThreshold
        // Row 0 is above the threshold, row 1 just below it.
        #expect(FilterEngine.candidates(in: snapshot, query: q, labelScores: [[t, t - 0.001, 1]]) == [0])
        // Without an embedding model, Vision decides alone.
        #expect(FilterEngine.candidates(in: snapshot, query: q).isEmpty)
        #expect(ResolvedQuery.labelPrompt("building") == "a photo of a building")
        #expect(ResolvedQuery.labelPrompt("ocean") == "a photo of an ocean")
    }

    @Test func scopeAndAvailability() {
        let a = UUID(), b = UUID()
        let old = Date(timeIntervalSinceNow: -30 * 86400)
        let imgs = [
            Self.image(folder: a, added: old),
            Self.image(folder: b),
            Self.image(folder: a, available: false),
        ]
        #expect(run(imgs, .empty) == [0, 1])
        #expect(run(imgs, .empty, scope: .folder(a)) == [0])
        #expect(run(imgs, .empty, scope: .addedSince(Date(timeIntervalSinceNow: -7 * 86400))) == [1])
    }

    @Test func chipsRemoveCleanly() {
        let f = QueryFilters(colours: [.init(.blue, .mostly)], people: .any, freeText: "sunset")
        #expect(f.chips.map(\.title) == ["mostly blue", "with people", "“sunset”"])
        let without = f.removing(f.chips[1])
        #expect(without.people == nil)
        #expect(without.colours == f.colours)
        #expect(without.chips.count == 2)
    }

    @Test func looksUtilityBestShotsAndText() {
        func img(_ look: LookMetrics, text: String = "", aesthetics: Float? = nil, utility: Bool = false) -> ImageFeatures {
            ImageFeatures(look: look, recognizedText: ImageFeatures.foldForSearch(text), aesthetics: aesthetics, isUtility: utility)
        }
        let bright = LookMetrics(brightness: 0.8, contrast: 0.1, saturation: 0.05, warmth: 0.05, colourfulShare: 0.9)
        let bw = LookMetrics(brightness: 0.3, contrast: 0.3, saturation: 0.005, warmth: 0, colourfulShare: 0.01)
        let imgs = [
            img(bright, text: "Café Ouvert\nSALE", aesthetics: 0.8),
            img(bw, aesthetics: -0.2, utility: true),
            img(LookMetrics.neutral, aesthetics: 0.6, utility: true), // a flat-lay Vision calls "utility"
        ]
        #expect(run(imgs, QueryFilters(looks: [.bright])) == [0])
        #expect(run(imgs, QueryFilters(utility: .with)) == [1])
        #expect(run(imgs, QueryFilters(looks: [.warm])) == [0])
        #expect(run(imgs, QueryFilters(looks: [.blackAndWhite])) == [1])
        #expect(run(imgs, QueryFilters(looks: [.dark, .highContrast])) == [1])
        #expect(run(imgs, QueryFilters(utility: .without)) == [0, 2])
        #expect(run(imgs, QueryFilters(bestShots: true)) == [0])
        #expect(run(imgs, QueryFilters(textQuery: "cafe sale")) == [0])
        #expect(run(imgs, QueryFilters(textQuery: "closed")).isEmpty)
    }

    @Test func backgroundColourUsesTheBackgroundShares() {
        var product = Self.image(blue: 0.5)
        product.subjectShares = Self.shares([.blue: 1])
        product.backgroundShares = Self.shares([.white: 1])
        let unknown = Self.image(blue: 0.5) // no saliency: falls back to the whole image
        let f = QueryFilters(colours: [.init(.white, .mostly, region: .background)])
        #expect(run([product, unknown], f) == [0, 1])
        #expect(run([product], QueryFilters(colours: [.init(.blue, .mostly, region: .background)])).isEmpty)
    }

    @Test func styleTagsAreJudgedAgainstTheLibrary() {
        var snapshot = IndexSnapshot(dimension: 2)
        for _ in 0..<40 { snapshot.upsert(ImageFeatures(embedding: [1, 0])) }
        let q = ResolvedQuery(filters: QueryFilters(styles: [.night]), resolver: .empty)
        // 38 ordinary rows at cos −0.02, one clear night shot (0.12), one weak one (0.03).
        var scores = [Float](repeating: -0.02, count: 40)
        scores[3] = 0.12; scores[7] = 0.03
        #expect(FilterEngine.candidates(in: snapshot, query: q, styleScores: [scores]) == [3])
        // No embedding model: the tag can't be judged and is ignored.
        #expect(FilterEngine.candidates(in: snapshot, query: q).count == 40)
    }

    @Test func parentLabels() {
        let out = LabelResolver.addingParents([("skyscraper", 0.4), ("dog", 0.9), ("structure", 0.8)])
        let d = Dictionary(uniqueKeysWithValues: out)
        #expect(d["building"] == 0.4 && d["animal"] == 0.9)
        #expect(out.first?.0 == "animal" || out.first?.0 == "dog")
    }

    @Test func savedLooksFromBeforeDecode() throws {
        let old = #"{"colours":[{"bucket":"blue","mode":"mostly"}],"labels":["dog"]}"#
        let f = try JSONDecoder().decode(QueryFilters.self, from: Data(old.utf8))
        #expect(f.colours == [.init(.blue, .mostly)] && f.labels == ["dog"] && f.looks.isEmpty && !f.bestShots)
    }

    @Test func snapshotRemoveKeepsMatrixAligned() {
        var s = IndexSnapshot(dimension: 2)
        let ids = (0..<3).map { _ in UUID() }
        for (i, id) in ids.enumerated() {
            s.upsert(ImageFeatures(id: id, embedding: [Float(i), 1]))
        }
        s.remove(id: ids[0])
        #expect(s.count == 2)
        for (r, row) in s.rows.enumerated() {
            #expect(Array(s.matrix[(r * 2)..<(r * 2 + 2)]) == row.embedding!)
        }
    }
}
