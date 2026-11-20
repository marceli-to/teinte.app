import Foundation

/// The "your library so far, by colour" band: one dominant colour per image, sorted by hue, sampled down.
public enum ColourBand {
    /// Up to `limit` colours. Chromatic colours come first, by hue starting at blue and going round
    /// (blue → purple → red → orange → yellow → green → teal), then achromatic ones from dark to light.
    public static func swatches(from palettes: [[PaletteEntry]], limit: Int = 40) -> [OKLab] {
        let dominant = palettes.compactMap { $0.first?.colour }
        guard !dominant.isEmpty else { return [] }
        let chromatic = dominant.filter { $0.chroma >= ColourBucketMapper.achromaticChroma }
        let grey = dominant.filter { $0.chroma < ColourBucketMapper.achromaticChroma }

        // Start the wheel just below blue (220°) so teal ends the band and blue starts it.
        // Within a 12° slice, dark before light.
        func key(_ c: OKLab) -> (Int, Float) {
            var h = c.hue - 220
            if h < 0 { h += 360 }
            return (Int(h / 12), c.l)
        }
        let sortedChromatic = chromatic.sorted { key($0) < key($1) }
        let sortedGrey = grey.sorted { $0.l < $1.l }
        let all = sortedChromatic + sortedGrey
        guard all.count > limit else { return all }

        // Even sampling keeps the proportions of the library.
        let step = Double(all.count) / Double(limit)
        return (0..<limit).map { all[Int(Double($0) * step + step / 2)] }
    }
}
