import CoreGraphics
import Testing
@testable import TeinteCore

@Suite("Colour bucket mapping")
struct ColourBucketTests {
    /// Reference colours → expected bucket. Borderline cases are documented next to them.
    static let references: [(String, String, ColourBucket)] = [
        ("red", "FF0000", .red), ("maroon", "800000", .red), ("crimson", "DC143C", .red),
        ("tomato", "FF6347", .red),
        ("terracotta accent", "B8502B", .red),          // h≈39°, right at the red/orange edge: reads as red
        ("dark-mode accent", "E07A50", .orange),         // h≈42.5°, lighter: orange
        ("orange", "FFA500", .orange), ("dark orange", "FF8C00", .orange),
        ("chocolate", "D2691E", .brown), ("saddle brown", "8B4513", .brown), ("sienna", "A0522D", .brown),
        ("tan", "D2B48C", .brown),
        ("gold", "FFD700", .yellow), ("yellow", "FFFF00", .yellow), ("khaki", "F0E68C", .yellow),
        ("green", "00FF00", .green), ("forest", "228B22", .green), ("sage", "8F9E7B", .green),
        ("icon green", "2F5E4E", .green),               // h≈169°: green/teal boundary, reads as green
        ("teal", "008080", .teal), ("turquoise", "40E0D0", .teal), ("cyan", "00FFFF", .teal),
        ("sky blue", "87CEEB", .blue), ("steel blue", "4682B4", .blue), ("blue", "0000FF", .blue),
        ("navy", "000080", .blue),
        ("mockup blue", "4A6E8C", .blue), ("hazy sky", "B8C9D9", .blue), ("mockup dark blue", "2C4760", .blue),
        ("violet", "8A2BE2", .purple), ("purple", "800080", .purple),
        ("magenta", "FF00FF", .pink), ("hot pink", "FF69B4", .pink), ("pink", "FFC0CB", .pink),
        ("salmon", "FA8072", .pink),                     // light warm red: pink rather than orange
        ("white", "FFFFFF", .white), ("cream", "FFFDD0", .white), ("beige", "F5F5DC", .white),
        ("ground", "ECEEE8", .white),
        ("lines", "D6DAD1", .grey), ("grey", "808080", .grey),
        ("ink", "1E2621", .black), ("black", "000000", .black),
    ]

    @Test("reference colours", arguments: references)
    func reference(name: String, hex: String, expected: ColourBucket) {
        let c = OKLab(hex: hex)!
        #expect(ColourBucketMapper.bucket(for: c) == expected, "\(name) #\(hex) L=\(c.l) C=\(c.chroma) h=\(c.hue)")
    }

    @Test func oklabRoundTrip() {
        for hex in ["B8502B", "4A6E8C", "ECEEE8", "1E2621"] {
            let c = OKLab(hex: hex)!
            let rgb = c.srgb
            let back = OKLab(srgbR: rgb.r, g: rgb.g, b: rgb.b)
            #expect(abs(back.l - c.l) < 0.001 && abs(back.a - c.a) < 0.001 && abs(back.b - c.b) < 0.001)
        }
    }
}

@Suite("Colour shares")
struct ColourShareTests {
    /// RGBA buffer split into horizontal bands of solid colours.
    static func bands(_ parts: [(hex: String, fraction: Double)], side: Int = 64) -> [UInt8] {
        var px: [UInt8] = []
        var rows = 0
        for (i, part) in parts.enumerated() {
            let n = i == parts.count - 1 ? side - rows : Int((part.fraction * Double(side)).rounded())
            let v = UInt32(part.hex, radix: 16)!
            for _ in 0..<(n * side) { px += [UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF), 255] }
            rows += n
        }
        return px
    }

    @Test func seventyBlueThirtyWhite() {
        let profile = ColourAnalyzer().analyze(rgba: Self.bands([("4A6E8C", 0.7), ("FFFFFF", 0.3)]))
        #expect(abs(profile.share(of: .blue) - 0.70) <= 0.03)
        #expect(abs(profile.share(of: .white) - 0.30) <= 0.03)
    }

    @Test func sharesSumToOne() {
        let profile = ColourAnalyzer().analyze(rgba: Self.bands([
            ("B8502B", 0.2), ("2F5E4E", 0.2), ("4A6E8C", 0.2), ("ECEEE8", 0.2), ("1E2621", 0.2),
        ]))
        #expect(abs(profile.bucketShares.reduce(0, +) - 1) < 0.0001)
        #expect(profile.palette.count == 5)
        #expect(profile.palette == profile.palette.sorted { $0.share > $1.share })
    }

    @Test func deterministic() {
        // Noisy image so k-means has real work to do.
        var rng = SplitMix64(seed: 42)
        var px: [UInt8] = []
        for _ in 0..<(64 * 64) {
            px += [UInt8(rng.next() % 256), UInt8(rng.next() % 256), UInt8(rng.next() % 256), 255]
        }
        let a = ColourAnalyzer().analyze(rgba: px)
        let b = ColourAnalyzer().analyze(rgba: px)
        #expect(a == b)
    }

    @Test func transparentPixelsIgnored() {
        var px = Self.bands([("0000FF", 0.5), ("FF0000", 0.5)])
        // Make the red half transparent.
        for i in stride(from: px.count / 2, to: px.count, by: 4) { px[i + 3] = 0 }
        let profile = ColourAnalyzer().analyze(rgba: px)
        #expect(profile.share(of: .blue) > 0.99)
    }

    @Test func analyzesCGImage() throws {
        let px = Self.bands([("B8502B", 0.6), ("ECEEE8", 0.4)], side: 32)
        let provider = CGDataProvider(data: Data(px) as CFData)!
        let image = CGImage(
            width: 32, height: 32, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 128,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let profile = ColourAnalyzer().analyze(image)
        // Terracotta sits on the red/brown border (h≈39°), so it counts towards both.
        #expect(profile.share(of: .red) > 0.2 && profile.share(of: .brown) > 0.1)
        #expect(abs(profile.share(of: .red) + profile.share(of: .brown) + profile.share(of: .orange) - 0.6) < 0.06)
        #expect(abs(profile.share(of: .white) - 0.4) < 0.06)
    }

    @Test func clearColoursStayInOneBucket() {
        for (hex, bucket) in [("1E5BC6", ColourBucket.blue), ("2E8B3A", .green), ("C8102E", .red)] {
            let w = ColourBucketMapper.weights(for: OKLab(hex: hex)!)
            #expect(w.count == 1 && w[0].0 == bucket, "\(hex): \(w)")
        }
    }

    @Test func borderColoursCountTowardsBoth() {
        let w = Dictionary(uniqueKeysWithValues: ColourBucketMapper.weights(for: OKLab(hex: "B8502B")!))
        #expect((w[.red] ?? 0) > 0.2 && (w[.brown] ?? 0) > 0.2)
        #expect(abs(w.values.reduce(0, +) - 1) < 1e-5)
    }

    @Test func saliencySplitsSubjectFromBackground() {
        // Left half red (the subject), right half white.
        let side = 32
        var px: [UInt8] = []
        for _ in 0..<side { for x in 0..<side { px += x < side / 2 ? [200, 20, 30, 255] : [250, 250, 250, 255] } }
        let map = WeightMap(width: 2, height: 1, values: [1, 0])
        let profile = ColourAnalyzer().analyze(rgba: px, width: side, saliency: map)
        #expect(profile.subjectShares[ColourBucket.red.index] > 0.95)
        #expect(profile.backgroundShares[ColourBucket.white.index] > 0.95)
        // Subject weighs more than the background: 1 vs `backgroundWeight`.
        let expected = 1 / (1 + ColourAnalyzer.backgroundWeight)
        #expect(abs(profile.share(of: .red) - expected) < 0.03)
        // Without a map: plain pixel shares, no subject/background.
        let plain = ColourAnalyzer().analyze(rgba: px, width: side)
        #expect(abs(plain.share(of: .red) - 0.5) < 0.03 && plain.subjectShares.isEmpty)
    }

    @Test func lookMetrics() {
        let grey = ColourAnalyzer().analyze(rgba: Self.bands([("101010", 0.5), ("F0F0F0", 0.5)])).look
        #expect(grey.isBlackAndWhite)
        #expect(grey.contrast > 0.35)
        let warm = ColourAnalyzer().analyze(rgba: Self.bands([("E8A040", 1)])).look
        let cool = ColourAnalyzer().analyze(rgba: Self.bands([("4080C8", 1)])).look
        #expect(warm.warmth > 0.05 && cool.warmth < -0.03)
        #expect(!warm.isBlackAndWhite && warm.saturation > 0.1 && warm.contrast < 0.01)
        let dark = ColourAnalyzer().analyze(rgba: Self.bands([("202428", 1)])).look
        #expect(dark.brightness < 0.3)
    }
}

import Foundation
