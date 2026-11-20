import CoreGraphics
import Foundation

/// One cluster of the k-means palette.
public struct PaletteEntry: Hashable, Sendable, Codable {
    public var colour: OKLab
    public var share: Float
    public var bucket: ColourBucket

    public init(colour: OKLab, share: Float, bucket: ColourBucket) {
        self.colour = colour; self.share = share; self.bucket = bucket
    }
}

/// The colour analysis result for one image.
public struct ColourProfile: Hashable, Sendable, Codable {
    /// Share per bucket, in `ColourBucket.allCases` order. Sums to ~1.
    public var bucketShares: [Float]
    /// Clusters sorted by share, largest first.
    public var palette: [PaletteEntry]

    public init(bucketShares: [Float], palette: [PaletteEntry]) {
        self.bucketShares = bucketShares; self.palette = palette
    }

    public func share(of bucket: ColourBucket) -> Float { bucketShares[bucket.index] }

    /// Buckets sorted by share, largest first, skipping empty ones.
    public var rankedBuckets: [(bucket: ColourBucket, share: Float)] {
        ColourBucket.allCases
            .map { ($0, bucketShares[$0.index]) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
    }

    public static let empty = ColourProfile(
        bucketShares: Array(repeating: 0, count: ColourBucket.allCases.count), palette: [])
}

/// Dominant-colour analysis: downscale → OKLab → k-means (k≈5) → buckets.
public struct ColourAnalyzer: Sendable {
    public var k: Int
    public var sampleSide: Int
    public var maxIterations: Int
    public var seed: UInt64

    public init(k: Int = 5, sampleSide: Int = 64, maxIterations: Int = 12, seed: UInt64 = 0x7E1_17E) {
        self.k = k; self.sampleSide = sampleSide; self.maxIterations = maxIterations; self.seed = seed
    }

    /// Analyse a CGImage. It's drawn into a small sRGB buffer first.
    public func analyze(_ image: CGImage) -> ColourProfile {
        guard let pixels = Self.rgbaPixels(of: image, side: sampleSide) else { return .empty }
        return analyze(rgba: pixels)
    }

    /// Analyse raw RGBA8 pixels (premultiplied or not; fully transparent pixels are skipped).
    public func analyze(rgba: [UInt8]) -> ColourProfile {
        var points: [OKLab] = []
        points.reserveCapacity(rgba.count / 4)
        var i = 0
        while i + 3 < rgba.count {
            if rgba[i + 3] > 16 {
                points.append(OKLab(r8: rgba[i], g8: rgba[i + 1], b8: rgba[i + 2]))
            }
            i += 4
        }
        guard !points.isEmpty else { return .empty }

        let clusters = KMeans.cluster(points, k: k, maxIterations: maxIterations, seed: seed)
        var shares = Array(repeating: Float(0), count: ColourBucket.allCases.count)
        var palette: [PaletteEntry] = []
        for cluster in clusters where cluster.share > 0 {
            let bucket = ColourBucketMapper.bucket(for: cluster.centroid)
            shares[bucket.index] += cluster.share
            palette.append(PaletteEntry(colour: cluster.centroid, share: cluster.share, bucket: bucket))
        }
        palette.sort { $0.share > $1.share }
        return ColourProfile(bucketShares: shares, palette: palette)
    }

    /// Draw an image into a side×side sRGB RGBA8 buffer (aspect is not preserved; shares don't care).
    public static func rgbaPixels(of image: CGImage, side: Int) -> [UInt8]? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var buffer = [UInt8](repeating: 0, count: side * side * 4)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return ok ? buffer : nil
    }
}

/// Deterministic k-means++ in OKLab.
enum KMeans {
    struct Cluster { var centroid: OKLab; var share: Float }

    static func cluster(_ points: [OKLab], k: Int, maxIterations: Int, seed: UInt64) -> [Cluster] {
        let n = points.count
        let k = min(k, n)
        var rng = SplitMix64(seed: seed)

        // k-means++ initialisation.
        var centroids: [OKLab] = [points[Int(rng.next() % UInt64(n))]]
        var dist = points.map { distance2($0, centroids[0]) }
        while centroids.count < k {
            let total = dist.reduce(0, +)
            if total <= 0 { break } // all points identical to existing centroids
            var target = Float(Double(rng.next() % 1_000_000) / 1_000_000) * total
            var chosen = n - 1
            for j in 0..<n {
                target -= dist[j]
                if target <= 0 { chosen = j; break }
            }
            centroids.append(points[chosen])
            for j in 0..<n { dist[j] = min(dist[j], distance2(points[j], points[chosen])) }
        }

        var assignment = [Int](repeating: 0, count: n)
        for _ in 0..<maxIterations {
            var changed = false
            for j in 0..<n {
                var best = 0
                var bestD = Float.greatestFiniteMagnitude
                for (c, centroid) in centroids.enumerated() {
                    let d = distance2(points[j], centroid)
                    if d < bestD { bestD = d; best = c }
                }
                if assignment[j] != best { assignment[j] = best; changed = true }
            }
            var sums = [(Float, Float, Float, Int)](repeating: (0, 0, 0, 0), count: centroids.count)
            for j in 0..<n {
                let c = assignment[j]
                sums[c].0 += points[j].l; sums[c].1 += points[j].a; sums[c].2 += points[j].b; sums[c].3 += 1
            }
            for c in centroids.indices where sums[c].3 > 0 {
                let m = Float(sums[c].3)
                centroids[c] = OKLab(l: sums[c].0 / m, a: sums[c].1 / m, b: sums[c].2 / m)
            }
            if !changed { break }
        }

        var counts = [Int](repeating: 0, count: centroids.count)
        for c in assignment { counts[c] += 1 }
        return centroids.indices.map { Cluster(centroid: centroids[$0], share: Float(counts[$0]) / Float(n)) }
    }

    @inline(__always) static func distance2(_ p: OKLab, _ q: OKLab) -> Float {
        let dl = p.l - q.l, da = p.a - q.a, db = p.b - q.b
        return dl * dl + da * da + db * db
    }
}

/// Small deterministic PRNG so k-means is reproducible in tests.
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
