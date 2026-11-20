import AppKit
import SwiftUI
import TeinteCore

/// Colour tokens and type styles. One accent only.
enum Theme {
    static let ink = Color(light: 0x1E2621, dark: 0xECEEE8)
    static let ground = Color(light: 0xECEEE8, dark: 0x1E2621)
    static let surface = Color(light: 0xFFFFFF, dark: 0x283029)
    static let muted = Color(light: 0x47514A, dark: 0xA9B1A9)
    static let line = Color(light: 0xD6DAD1, dark: 0x3A443D)
    static let accent = Color(light: 0xB8502B, dark: 0xE07A50)
    /// Fields and pills (search bar, chips, toggle thumb): a soft lift off the ground instead of glaring white.
    static let field = Color(light: 0xF4F5F0, dark: 0x283029)
    /// Selected and hovered rows: a quiet ink tint, darker than the ground.
    static let selection = Color(light: 0x1E2621, lightAlpha: 0.075, dark: 0xECEEE8, darkAlpha: 0.08)
    /// Icon buttons while pressed: a step deeper than `selection`.
    static let pressed = Color(light: 0x1E2621, lightAlpha: 0.14, dark: 0xECEEE8, darkAlpha: 0.15)
    /// The well behind the grid/list toggle.
    static let well = Color(light: 0xE1E4DC, dark: 0x252D27)
    /// Placeholder behind thumbnails that haven't loaded yet.
    static let placeholder = Color(light: 0xDDE1D8, dark: 0x2C342E)
    /// A hairline ring that keeps light swatches visible on the light ground (and dark ones on dark).
    static let ring = Color(light: 0x1E2621, lightAlpha: 0.14, dark: 0xECEEE8, darkAlpha: 0.22)
    /// Text on the ink button.
    static let onInk = Color(light: 0xFFFFFF, dark: 0x1E2621)

    static func swatch(_ bucket: ColourBucket) -> Color {
        let s = bucket.swatch
        return Color(.sRGB, red: s.r, green: s.g, blue: s.b)
    }

    static func swatch(_ c: OKLab) -> Color {
        let s = c.srgb
        return Color(.sRGB, red: Double(s.r), green: Double(s.g), blue: Double(s.b))
    }
}

// MARK: - Type

extension Font {
    /// Geist and Geist Mono (OFL), bundled as static cuts of the variable fonts.
    enum SansWeight: String { case light = "Light", regular = "Regular", medium = "Medium", semibold = "SemiBold" }
    enum MonoWeight: String { case regular = "Regular", medium = "Medium" }

    static func sans(_ size: CGFloat, _ weight: SansWeight = .regular) -> Font {
        .custom("Geist-\(weight.rawValue)", fixedSize: size)
    }

    static func mono(_ size: CGFloat, _ weight: MonoWeight = .regular) -> Font {
        .custom("GeistMono-\(weight.rawValue)", fixedSize: size)
    }

    /// The big numbers: "24", "812". Light, so they read large but airy.
    static func display(_ size: CGFloat) -> Font { sans(size, .light) }
    static let title = sans(17, .semibold)
    static let body = sans(15, .regular)
    static let bodyStrong = sans(15, .medium)
    static let sidebarItem = sans(13, .regular)
    static let monoLabel = mono(11, .regular)
    static let monoSmall = mono(12)
}

extension View {
    /// Small uppercase mono section label ("LIBRARY", "COLOURS").
    func sectionLabel() -> some View {
        self.font(.monoLabel).tracking(1.2).textCase(.uppercase).foregroundStyle(Theme.muted)
    }
}

// MARK: - Helpers

extension Color {
    init(light: UInt32, lightAlpha: CGFloat = 1, dark: UInt32, darkAlpha: CGFloat = 1) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension Int {
    /// "1,240"
    var grouped: String { formatted(.number.grouping(.automatic)) }
}
