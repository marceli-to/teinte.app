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
    /// Weighted towards the subject when a saliency map was given.
    public var bucketShares: [Float]
    /// Clusters sorted by share, largest first.
    public var palette: [PaletteEntry]
    /// Shares of the salient part (the subject) and of the rest. Empty without a saliency map.
    public var subjectShares: [Float]
    public var backgroundShares: [Float]
    /// Brightness, contrast, saturation, warmth, black and white. Unweighted: it describes the whole frame.
    public var look: LookMetrics

    public init(bucketShares: [Float], palette: [PaletteEntry], subjectShares: [Float] = [],
                backgroundShares: [Float] = [], look: LookMetrics = .neutral) {
        self.bucketShares = bucketShares; self.palette = palette
        self.subjectShares = subjectShares; self.backgroundShares = backgroundShares; self.look = look
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

/// A coarse saliency map: values 0…1, row-major, top row first.
public struct WeightMap: Hashable, Sendable {
    public var width: Int
    public var height: Int
    public var values: [Float]

    public init(width: Int, height: Int, values: [Float]) {
        self.width = width; self.height = height; self.values = values
    }

    /// Nearest sample at a normalised position (x right, y down, both 0…1).
    public func value(x: Float, y: Float) -> Float {
        let i = min(max(Int(x * Float(width)), 0), width - 1)
        let j = min(max(Int(y * Float(height)), 0), height - 1)
        return values[j * width + i]
    }

    /// Scaled so the peak is 1. Nil when the map is flat (no subject found).
    public func normalized() -> WeightMap? {
        guard let peak = values.max(), peak > 1e-4 else { return nil }
        return WeightMap(width: width, height: height, values: values.map { min(max($0 / peak, 0), 1) })
    }
}

/// Dominant-colour analysis: downscale (aspect kept) → OKLab → weighted k-means (k≈8) → soft buckets.
public struct ColourAnalyzer: Sendable {
    public var k: Int
    /// Longest side of the sample grid.
    public var sampleSide: Int
    public var maxIterations: Int
    public var seed: UInt64
    /// Weight of a pixel the saliency map calls background, relative to the subject (1).
    public static let backgroundWeight: Float = 0.3

    public init(k: Int = 8, sampleSide: Int = 128, maxIterations: Int = 12, seed: UInt64 = 0x7E1_17E) {
        self.k = k; self.sampleSide = sampleSide; self.maxIterations = maxIterations; self.seed = seed
    }

    /// Analyse a CGImage. It's drawn into a small sRGB buffer first, keeping its aspect ratio.
    public func analyze(_ image: CGImage, saliency: WeightMap? = nil) -> ColourProfile {
        let scale = Float(sampleSide) / Float(max(image.width, image.height, 1))
        let w = max(1, min(sampleSide, Int((Float(image.width) * scale).rounded())))
        let h = max(1, min(sampleSide, Int((Float(image.height) * scale).rounded())))
        guard let pixels = Self.rgbaPixels(of: image, width: w, height: h) else { return .empty }
        return analyze(rgba: pixels, width: w, saliency: saliency)
    }

    /// Analyse raw RGBA8 pixels (premultiplied or not; fully transparent pixels are skipped).
    /// `width` is only needed to place the saliency map; without it the buffer is taken as square.
    public func analyze(rgba: [UInt8], width: Int? = nil, saliency: WeightMap? = nil) -> ColourProfile {
        let count = rgba.count / 4
        let w = width ?? max(1, Int(Double(count).squareRoot()))
        let h = max(1, count / w)
        let map = saliency?.normalized()

        var points: [OKLab] = []
        var salience: [Float] = []
        points.reserveCapacity(count)
        salience.reserveCapacity(count)
        for p in 0..<count {
            let i = p * 4
            guard rgba[i + 3] > 16 else { continue }
            points.append(OKLab(r8: rgba[i], g8: rgba[i + 1], b8: rgba[i + 2]))
            if let map {
                salience.append(map.value(x: (Float(p % w) + 0.5) / Float(w), y: (Float(p / w) + 0.5) / Float(h)))
            }
        }
        guard !points.isEmpty else { return .empty }

        let look = LookMetrics(points)
        let weights = map == nil ? nil : salience.map { Self.backgroundWeight + (1 - Self.backgroundWeight) * $0 }
        let result = KMeans.cluster(points, weights: weights, k: k, maxIterations: maxIterations, seed: seed)

        // Shares come from the pixels themselves (soft-bucketed, saliency-weighted), not from the
        // cluster centroids: a centroid averages dull brick and mortar into grey, the pixels don't.
        let n = ColourBucket.allCases.count
        var shares = [Float](repeating: 0, count: n)
        var subject = [Float](repeating: 0, count: n)
        var background = [Float](repeating: 0, count: n)
        var cache: [Int32: [(ColourBucket, Float)]] = [:]
        var total: Float = 0, subjectTotal: Float = 0, backgroundTotal: Float = 0
        for (j, p) in points.enumerated() {
            let key = Self.cacheKey(p)
            let bucketWeights: [(ColourBucket, Float)]
            if let cached = cache[key] { bucketWeights = cached } else {
                bucketWeights = ColourBucketMapper.weights(for: p)
                cache[key] = bucketWeights
            }
            let w = weights?[j] ?? 1
            let s = map == nil ? 0 : salience[j]
            total += w; subjectTotal += s; backgroundTotal += 1 - s
            for (bucket, share) in bucketWeights {
                shares[bucket.index] += w * share
                if map != nil {
                    subject[bucket.index] += s * share
                    background[bucket.index] += (1 - s) * share
                }
            }
        }
        shares = shares.map { $0 / max(total, 1e-9) }
        let hasMap = map != nil && subjectTotal > 1e-3 && backgroundTotal > 1e-3
        if hasMap {
            subject = subject.map { $0 / subjectTotal }
            background = background.map { $0 / backgroundTotal }
        }

        var palette = result.clusters.filter { $0.share > 0 }.map {
            PaletteEntry(colour: $0.centroid, share: $0.share, bucket: ColourBucketMapper.bucket(for: $0.centroid))
        }
        palette.sort { $0.share > $1.share }
        return ColourProfile(
            bucketShares: shares, palette: palette,
            subjectShares: hasMap ? subject : [], backgroundShares: hasMap ? background : [],
            look: look)
    }

    /// OKLab quantised to a step of ~0.01 (L) and ~0.005 (a, b): far below what changes a bucket.
    @inline(__always) static func cacheKey(_ p: OKLab) -> Int32 {
        let l = Int32(min(max(p.l, 0), 1) * 100)
        let a = Int32(min(max(p.a + 0.4, 0), 0.8) * 200)
        let b = Int32(min(max(p.b + 0.4, 0), 0.8) * 200)
        return l << 16 | a << 8 | b
    }

    /// Draw an image into a width×height sRGB RGBA8 buffer.
    public static func rgbaPixels(of image: CGImage, width: Int, height: Int) -> [UInt8]? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? buffer : nil
    }
}

/// Whole-frame tone measurements, from the OKLab pixels.
public struct LookMetrics: Hashable, Sendable, Codable {
    /// Mean lightness, 0…1.
    public var brightness: Float
    /// Standard deviation of lightness.
    public var contrast: Float
    /// Mean chroma (OKLab; ~0.2 is very saturated).
    public var saturation: Float
    /// Mean of the yellow–blue axis plus half the red–green axis: > 0 warm, < 0 cool.
    public var warmth: Float
    /// Share of pixels with visible colour (chroma ≥ 0.03). Near 0 for black and white.
    public var colourfulShare: Float

    public init(brightness: Float, contrast: Float, saturation: Float, warmth: Float, colourfulShare: Float) {
        self.brightness = brightness; self.contrast = contrast; self.saturation = saturation
        self.warmth = warmth; self.colourfulShare = colourfulShare
    }

    public static let neutral = LookMetrics(brightness: 0.5, contrast: 0.15, saturation: 0.06, warmth: 0, colourfulShare: 1)

    public init(_ points: [OKLab]) {
        guard !points.isEmpty else { self = .neutral; return }
        var sumL: Double = 0, sumL2: Double = 0, sumC: Double = 0, sumW: Double = 0
        var colourful = 0
        for p in points {
            let c = p.chroma
            sumL += Double(p.l); sumL2 += Double(p.l * p.l); sumC += Double(c)
            sumW += Double(p.b + 0.5 * p.a)
            if c >= 0.03 { colourful += 1 }
        }
        let n = Double(points.count)
        let mean = sumL / n
        self.init(
            brightness: Float(mean), contrast: Float(max(sumL2 / n - mean * mean, 0).squareRoot()),
            saturation: Float(sumC / n), warmth: Float(sumW / n), colourfulShare: Float(Double(colourful) / n))
    }

    public var isBlackAndWhite: Bool { colourfulShare < 0.03 && saturation < 0.012 }
}

/// Deterministic, optionally weighted k-means++ in OKLab.
enum KMeans {
    struct Cluster { var centroid: OKLab; var share: Float }
    struct Result { var clusters: [Cluster]; var assignment: [Int] }

    static func cluster(_ points: [OKLab], k: Int, maxIterations: Int, seed: UInt64) -> [Cluster] {
        cluster(points, weights: nil, k: k, maxIterations: maxIterations, seed: seed).clusters
    }

    /// `weights` (one per point) count towards centroids and shares; nil = all 1.
    static func cluster(_ points: [OKLab], weights: [Float]?, k: Int, maxIterations: Int, seed: UInt64) -> Result {
        let n = points.count
        let k = min(k, n)
        var rng = SplitMix64(seed: seed)
        func weight(_ j: Int) -> Float { weights?[j] ?? 1 }

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
            var sums = [(Float, Float, Float, Float)](repeating: (0, 0, 0, 0), count: centroids.count)
            for j in 0..<n {
                let c = assignment[j], w = weight(j)
                sums[c].0 += points[j].l * w; sums[c].1 += points[j].a * w; sums[c].2 += points[j].b * w; sums[c].3 += w
            }
            for c in centroids.indices where sums[c].3 > 0 {
                let m = sums[c].3
                centroids[c] = OKLab(l: sums[c].0 / m, a: sums[c].1 / m, b: sums[c].2 / m)
            }
            if !changed { break }
        }

        var mass = [Float](repeating: 0, count: centroids.count)
        for j in 0..<n { mass[assignment[j]] += weight(j) }
        let total = max(mass.reduce(0, +), 1e-9)
        return Result(
            clusters: centroids.indices.map { Cluster(centroid: centroids[$0], share: mass[$0] / total) },
            assignment: assignment)
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
