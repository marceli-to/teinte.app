import Foundation

/// The 12 named colour buckets Teinte filters on.
public enum ColourBucket: String, CaseIterable, Codable, Hashable, Sendable {
    case red, orange, yellow, green, teal, blue, purple, pink, brown, black, white, grey

    public var index: Int { Self.allCases.firstIndex(of: self)! }

    /// A representative swatch colour (sRGB 0…1) for chips and debug output.
    public var swatch: (r: Double, g: Double, b: Double) {
        switch self {
        case .red: (0.78, 0.20, 0.17)
        case .orange: (0.88, 0.48, 0.20)
        case .yellow: (0.92, 0.78, 0.25)
        case .green: (0.30, 0.52, 0.30)
        case .teal: (0.18, 0.50, 0.50)
        case .blue: (0.29, 0.43, 0.55)
        case .purple: (0.45, 0.30, 0.55)
        case .pink: (0.90, 0.58, 0.66)
        case .brown: (0.48, 0.33, 0.22)
        case .black: (0.10, 0.12, 0.11)
        case .white: (0.97, 0.97, 0.95)
        case .grey: (0.55, 0.57, 0.55)
        }
    }

    /// Whether the swatch is light enough to need a hairline ring on the light ground.
    public var isLight: Bool { self == .white || self == .yellow }
}

/// A colour in the OKLab perceptual space.
public struct OKLab: Hashable, Sendable, Codable {
    public var l: Float
    public var a: Float
    public var b: Float

    public init(l: Float, a: Float, b: Float) {
        self.l = l; self.a = a; self.b = b
    }

    public var chroma: Float { (a * a + b * b).squareRoot() }

    /// Hue in degrees, 0..<360.
    public var hue: Float {
        let h = atan2(b, a) * 180 / .pi
        return h < 0 ? h + 360 : h
    }

    /// From 8-bit sRGB.
    public init(r8: UInt8, g8: UInt8, b8: UInt8) {
        self.init(srgbR: Float(r8) / 255, g: Float(g8) / 255, b: Float(b8) / 255)
    }

    /// From gamma-encoded sRGB components in 0…1.
    public init(srgbR: Float, g: Float, b: Float) {
        let r = OKLab.toLinear(srgbR), gl = OKLab.toLinear(g), bl = OKLab.toLinear(b)
        let lc = cbrtf(0.4122214708 * r + 0.5363325363 * gl + 0.0514459929 * bl)
        let mc = cbrtf(0.2119034982 * r + 0.6806995451 * gl + 0.1073969566 * bl)
        let sc = cbrtf(0.0883024619 * r + 0.2817188376 * gl + 0.6299787005 * bl)
        self.l = 0.2104542553 * lc + 0.7936177850 * mc - 0.0040720468 * sc
        self.a = 1.9779984951 * lc - 2.4285922050 * mc + 0.4505937099 * sc
        self.b = 0.0259040371 * lc + 0.7827717662 * mc - 0.8086757660 * sc
    }

    /// From a hex string like "#B8502B" or "B8502B".
    public init?(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(r8: UInt8(v >> 16 & 0xFF), g8: UInt8(v >> 8 & 0xFF), b8: UInt8(v & 0xFF))
    }

    /// Back to gamma-encoded sRGB, clamped to 0…1.
    public var srgb: (r: Float, g: Float, b: Float) {
        let lc = l + 0.3963377774 * a + 0.2158037573 * b
        let mc = l - 0.1055613458 * a - 0.0638541728 * b
        let sc = l - 0.0894841775 * a - 1.2914855480 * b
        let l3 = lc * lc * lc, m3 = mc * mc * mc, s3 = sc * sc * sc
        let r = 4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3
        let g = -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3
        let bb = -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3
        return (OKLab.toGamma(r), OKLab.toGamma(g), OKLab.toGamma(bb))
    }

    @inline(__always) static func toLinear(_ c: Float) -> Float {
        c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
    }

    @inline(__always) static func toGamma(_ c: Float) -> Float {
        let x = min(max(c, 0), 1)
        return x <= 0.0031308 ? 12.92 * x : 1.055 * powf(x, 1 / 2.4) - 0.055
    }
}

/// Maps OKLab colours to named buckets.
///
/// The thresholds were set against measured OKLCh values of reference colours (see `ColourBucketTests`).
/// Pure sRGB red sits at h≈29°, orange ≈71°, yellow ≈110°, green ≈143°, teal/cyan ≈195°, blue ≈264°, purple/magenta ≈328°.
public enum ColourBucketMapper {
    /// Below this chroma a colour counts as black / grey / white.
    /// Low on purpose: hazy skies (#B8C9D9, C≈0.029) must still count as blue.
    public static let achromaticChroma: Float = 0.02

    public static func bucket(for c: OKLab) -> ColourBucket {
        let L = c.l, C = c.chroma, h = c.hue

        // Clamp the extremes first.
        if L < 0.18 { return .black }
        if L > 0.93 && C < 0.06 { return .white }

        if C < achromaticChroma {
            if L < 0.30 { return .black }
            if L >= 0.90 { return .white }
            return .grey
        }

        switch h {
        case 40..<75:       // orange zone
            if L < 0.65 || (C < 0.08 && L < 0.90) { return .brown }
            return .orange
        case 75..<120:      // yellow zone
            if L < 0.55 || (C < 0.08 && L < 0.85) { return .brown }
            return .yellow
        case 120..<175:
            return .green
        case 175..<220:
            return .teal
        case 220..<290:
            return .blue
        case 290..<345:     // purple zone
            return L >= 0.70 ? .pink : .purple
        default:            // red zone: 345..<360 and 0..<40
            return L >= 0.72 ? .pink : .red
        }
    }
}
