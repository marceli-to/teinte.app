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
        #expect(abs(profile.share(of: .red) - 0.6) < 0.06)
        #expect(abs(profile.share(of: .white) - 0.4) < 0.06)
    }
}

import Foundation
