import CoreGraphics
import Foundation
import Testing
import TeinteCore
@testable import Teinte

/// End-to-end checks of the parts that need the app bundle: Core ML models, Vision, the index.
@Suite("Analysis pipeline", .serialized)
struct PipelineTests {
    static let embedder: SigLIPEmbedder? = try? SigLIPEmbedder.loadFromBundle().get()

    struct Reference: Decodable {
        var text: String
        var embedding: [Float]
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        let na = l2Normalized(a), nb = l2Normalized(b)
        return zip(na, nb).map(*).reduce(0, +)
    }

    /// Swift tokenizer + Core ML text encoder vs. PyTorch fp32.
    @Test(.enabled(if: embedder != nil))
    func textEmbeddingParity() async throws {
        let bundle = Bundle(for: BundleMarker.self)
        let url = try #require(bundle.url(forResource: "siglip_text_embeddings", withExtension: "json"))
        let refs = try JSONDecoder().decode([Reference].self, from: Data(contentsOf: url))
        let e = try #require(Self.embedder)
        for ref in refs {
            let v = try await e.embed(text: ref.text)
            let c = Self.cosine(v, ref.embedding)
            #expect(c > 0.99, "\(ref.text): cosine to PyTorch \(c)")
        }
    }

    /// Synthetic "sky" and "fire" images: the matching description must win.
    @Test(.enabled(if: embedder != nil))
    func zeroShotSanity() async throws {
        let e = try #require(Self.embedder)
        let sky = Self.gradient(top: (0.35, 0.55, 0.85), bottom: (0.75, 0.85, 0.95))
        let fire = Self.gradient(top: (0.9, 0.3, 0.05), bottom: (1.0, 0.75, 0.1))
        let vSky = try await e.embed(image: sky), vFire = try await e.embed(image: fire)
        let tSky = try await e.embed(text: "a photo of a clear blue sky")
        let tFire = try await e.embed(text: "a photo of orange flames")
        #expect(Self.cosine(vSky, tSky) > Self.cosine(vSky, tFire))
        #expect(Self.cosine(vFire, tFire) > Self.cosine(vFire, tSky))
        #expect(vSky.count == e.dimension)
    }

    /// Colours + Vision + index + filters + ranking on synthetic images.
    @Test func endToEndSearch() async throws {
        let blue = Self.gradient(top: (0.29, 0.43, 0.55), bottom: (0.18, 0.28, 0.38))
        let red = Self.gradient(top: (0.72, 0.31, 0.17), bottom: (0.6, 0.2, 0.1))
        var features: [ImageFeatures] = []
        for (name, img) in [("blue.png", blue), ("red.png", red)] {
            let colours = ColourAnalyzer().analyze(img)
            let vision = try await VisionAnalyzer.analyze(img)
            let embedding = try await Self.embedder?.embed(image: img)
            features.append(ImageFeatures(
                fileName: name, pixelWidth: img.width, pixelHeight: img.height,
                bucketShares: colours.bucketShares, personCount: vision.personCount, faceCount: vision.faceCount,
                hasText: vision.hasText, labels: vision.labels.map(\.0), embedding: embedding))
        }
        let index = SearchIndex(dimension: Self.embedder?.dimension ?? 1, embeddings: nil)
        await index.upsert(features)

        let filters = RuleBasedParser().parseSync("mostly blue, no people")
        let outcome = await index.search(ResolvedQuery(filters: filters, resolver: .empty), vector: nil,
                                         scope: .all, calibration: .generic)
        #expect(outcome.hits.map(\.features.fileName) == ["blue.png"])
    }

    static func gradient(top: (Double, Double, Double), bottom: (Double, Double, Double), size: Int = 320) -> CGImage {
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let colours = [CGColor(srgbRed: top.0, green: top.1, blue: top.2, alpha: 1),
                       CGColor(srgbRed: bottom.0, green: bottom.1, blue: bottom.2, alpha: 1)] as CFArray
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colours, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: size), end: .zero, options: [])
        return ctx.makeImage()!
    }
}

final class BundleMarker {}
