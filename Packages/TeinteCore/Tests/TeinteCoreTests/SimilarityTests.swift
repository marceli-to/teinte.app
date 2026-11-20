import Foundation
import Testing
@testable import TeinteCore

@Suite("Find similar")
struct SimilarityTests {
    static func palette(_ hexes: [(String, Float)]) -> [PaletteEntry] {
        hexes.map { hex, share in
            let c = OKLab(hex: hex)!
            return PaletteEntry(colour: c, share: share, bucket: ColourBucketMapper.bucket(for: c))
        }
    }

    @Test func paletteSimilarityIsOneForTheSamePalette() {
        let p = Self.palette([("#B8502B", 0.6), ("#E8E4DA", 0.4)])
        #expect(abs(PaletteSimilarity.similarity(p, p) - 1) < 1e-5)
    }

    @Test func nearColoursCountAsClose() {
        let brick = Self.palette([("#9C3B2A", 1)])
        let terracotta = Self.palette([("#B8502B", 1)])
        let sky = Self.palette([("#7FA7D4", 1)])
        let near = PaletteSimilarity.similarity(brick, terracotta)
        let far = PaletteSimilarity.similarity(brick, sky)
        #expect(near > 0.5)
        #expect(far < 0.05)
    }

    @Test func sharesMatter() {
        let mostlyRed = Self.palette([("#B8502B", 0.8), ("#7FA7D4", 0.2)])
        let mostlyBlue = Self.palette([("#B8502B", 0.2), ("#7FA7D4", 0.8)])
        let red = Self.palette([("#B8502B", 1)])
        #expect(PaletteSimilarity.similarity(red, mostlyRed) > PaletteSimilarity.similarity(red, mostlyBlue))
    }

    /// Axis 0 = beach, axis 1 = city. Colours: warm or blue.
    static func snapshot() -> IndexSnapshot {
        var s = IndexSnapshot(dimension: 2)
        let warm = palette([("#C8643A", 1)]), blue = palette([("#4A6E8C", 1)])
        let rows: [(String, [Float], [PaletteEntry])] = [
            ("seed.jpg", [1, 0.1], warm),
            ("beach-warm.jpg", [1, 0.15], warm),
            ("beach-blue.jpg", [1, 0.12], blue),
            ("city-warm.jpg", [0.1, 1], warm),
            ("city-blue.jpg", [0.1, 1], blue),
        ]
        for (name, e, p) in rows {
            s.upsert(ImageFeatures(fileName: name, palette: p, embedding: l2Normalized(e)))
        }
        return s
    }

    @Test func contentAndColourBothCount() {
        let s = Self.snapshot()
        let ranked = Ranker.rankSimilar(candidates: Array(0..<s.count), in: s, seedRow: 0, textVector: nil)
        let names = ranked.map { s.rows[$0.row].fileName }
        #expect(names == ["beach-warm.jpg", "beach-blue.jpg", "city-warm.jpg", "city-blue.jpg"])
        #expect(ranked.map(\.match!) == ranked.map(\.match!).sorted(by: >))
    }

    @Test func seedIsLeftOut() {
        let s = Self.snapshot()
        let ranked = Ranker.rankSimilar(candidates: [0, 3], in: s, seedRow: 0, textVector: nil)
        #expect(ranked.map(\.row) == [3])
    }

    @Test func textQueryAddsToTheOrder() {
        let s = Self.snapshot()
        // Seed is a beach, but the text asks for a city: the warm city now beats the blue beach.
        let ranked = Ranker.rankSimilar(candidates: Array(0..<s.count), in: s, seedRow: 0,
                                        textVector: l2Normalized([0, 1]),
                                        ranking: .init(imageWeight: 0.65, colourWeight: 0.35, textWeight: 1.5,
                                                       zMidpoint: 2, zWidth: 0.5))
        let names = ranked.map { s.rows[$0.row].fileName }
        #expect(names.firstIndex(of: "city-warm.jpg")! < names.firstIndex(of: "beach-blue.jpg")!)
    }

    @Test func seedChipRoundTripsAndRemoves() throws {
        let seed = SimilarSeed(id: UUID(), fileName: "IMG_2041.jpg")
        let f = QueryFilters(colours: [.init(.blue, .mostly)], similarTo: seed)
        #expect(f.chips.first?.title == "like IMG_2041.jpg")
        #expect(!f.isEmpty)
        let decoded = try JSONDecoder().decode(QueryFilters.self, from: JSONEncoder().encode(f))
        #expect(decoded == f)
        let removed = f.removing(FilterChip(kind: .similar(seed)))
        #expect(removed.similarTo == nil)
        #expect(removed.colours.count == 1)
    }
}
