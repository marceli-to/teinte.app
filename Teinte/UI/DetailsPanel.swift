import AppKit
import ImageIO
import SwiftUI
import TeinteCore

/// The details panel on the right: everything the analysis knows about the selected image,
/// or a summary when several are selected.
struct DetailsPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Details").sectionLabel()
                Spacer()
                Button { model.inspectorVisible = false } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressScaleStyle())
                .help("Hide details (⌘I)")
                .accessibilityLabel("Hide details")
            }
            .padding(.horizontal, 20)
            .frame(height: 44)
            Rectangle().fill(Theme.line).frame(height: 1)

            ScrollView {
                Group {
                    if model.selectedIDs.count > 1 {
                        SelectionDetails(hits: model.selectedHits)
                    } else if let id = model.focusedID ?? model.selectedIDs.first {
                        ImageDetails(id: id).id(id)
                    } else {
                        Text("Select an image to see what Teinte found in it.")
                            .font(.sans(13))
                            .foregroundStyle(Theme.muted)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 80)
                    }
                }
                .padding(20)
            }
            .scrollIndicators(.automatic)
        }
        .background(Theme.ground)
    }
}

// MARK: - One image

private struct ImageDetails: View {
    @Environment(AppModel.self) private var model
    let id: UUID
    @State private var info: AppModel.ImageInfo?
    @State private var preview: CGImage?
    @State private var exif: ExifSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            previewImage
            if let info {
                header(info)
                facts(info)
                colours(info.features, palette: info.details?.palette ?? info.features.palette)
                look(info)
                seen(info)
                if let text = info.details?.recognizedText, !text.isEmpty { recognisedText(text) }
                actions
            }
        }
        .task(id: id) {
            info = await model.imageInfo(id)
            guard let url = info?.url else { return }
            let loaded = await Task.detached(priority: .userInitiated) { PreviewLoader.load(url, maxPixel: 900) }.value
            withAnimation(.easeOut(duration: 0.15)) {
                preview = loaded.image
                exif = loaded.exif
            }
        }
    }

    private var previewImage: some View {
        let aspect = info?.features.aspect ?? 4 / 3
        return Group {
            if let preview {
                Image(decorative: preview, scale: 1).resizable().aspectRatio(contentMode: .fit)
            } else {
                Thumbnail(id: id, aspect: aspect)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: 280)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityHidden(true)
    }

    private func header(_ info: AppModel.ImageInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(info.features.fileName)
                .font(.sans(15, .semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
                .textSelection(.enabled)
            Text(location(info))
                .font(.mono(11))
                .foregroundStyle(Theme.muted)
                .lineLimit(3)
                .textSelection(.enabled)
        }
    }

    private func location(_ info: AppModel.ImageInfo) -> String {
        let folder = info.folderName ?? ""
        guard let rel = info.details?.relativePath else { return folder }
        let dir = (rel as NSString).deletingLastPathComponent
        return dir.isEmpty ? folder : "\(folder)/\(dir)"
    }

    private func facts(_ info: AppModel.ImageInfo) -> some View {
        let f = info.features
        var rows: [(String, String)] = [("Size", "\(f.pixelWidth) × \(f.pixelHeight)")]
        if let d = info.details {
            rows.append(("File", ByteCountFormatter.string(fromByteCount: d.fileSize, countStyle: .file)))
        }
        if let taken = exif?.taken { rows.append(("Taken", taken.formatted(date: .abbreviated, time: .shortened))) }
        if let camera = exif?.camera { rows.append(("Camera", camera)) }
        if let lens = exif?.settings { rows.append(("Settings", lens)) }
        if let d = info.details, d.contentModified > .distantPast {
            rows.append(("Modified", d.contentModified.formatted(date: .abbreviated, time: .shortened)))
        }
        rows.append(("Added", f.addedAt.formatted(date: .abbreviated, time: .omitted)))
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(rows, id: \.0) { row in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(row.0)
                        .font(.sans(12))
                        .foregroundStyle(Theme.muted)
                        .frame(width: 64, alignment: .leading)
                    Text(row.1)
                        .font(.mono(12))
                        .foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func colours(_ f: ImageFeatures, palette: [PaletteEntry]) -> some View {
        Section("Colours") {
            // The palette as one proportional strip.
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(Array(palette.enumerated()), id: \.offset) { _, entry in
                        Theme.swatch(entry.colour)
                            .frame(width: geo.size.width * CGFloat(entry.share / max(totalShare(palette), 0.001)))
                    }
                }
            }
            .frame(height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.ring, lineWidth: 1) }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(topBuckets(f.bucketShares), id: \.0) { bucket, share in
                    HStack(spacing: 10) {
                        SwatchDot(bucket: bucket, size: 12)
                        Text(bucket.rawValue).font(.sans(13)).foregroundStyle(Theme.ink)
                        Spacer()
                        Text(percent(share)).font(.mono(12)).foregroundStyle(Theme.muted)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if f.subjectShares.count == f.bucketShares.count {
                regionRow("Subject", shares: f.subjectShares)
                regionRow("Background", shares: f.backgroundShares)
            }
        }
    }

    private func regionRow(_ title: String, shares: [Float]) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.sans(12)).foregroundStyle(Theme.muted).frame(width: 76, alignment: .leading)
            ForEach(topBuckets(shares).prefix(3), id: \.0) { bucket, share in
                HStack(spacing: 4) {
                    SwatchDot(bucket: bucket, size: 10)
                    Text(percent(share)).font(.mono(11)).foregroundStyle(Theme.ink)
                }
                .help(bucket.rawValue)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): " + topBuckets(shares).prefix(3).map { "\($0.0.rawValue) \(percent($0.1))" }.joined(separator: ", "))
    }

    private func look(_ info: AppModel.ImageInfo) -> some View {
        let m = info.features.look
        let looks = LookFilter.allCases.filter { $0.matches(m) }
        return Section("Look") {
            if !looks.isEmpty || !info.styles.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(looks, id: \.self) { Tag(text: $0.title, symbol: ChipButton.symbol(for: $0)) }
                    ForEach(info.styles, id: \.self) { Tag(text: $0.title, symbol: ChipButton.symbol(for: $0)) }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Meter(title: "Brightness", value: m.brightness)
                Meter(title: "Contrast", value: m.contrast / 0.35)
                Meter(title: "Saturation", value: m.saturation / 0.1)
                if let a = info.features.aesthetics {
                    Meter(title: "Quality", value: (a + 1) / 2,
                          note: a >= FilterEngine.bestShotThreshold ? "best shot" : nil)
                }
            }
        }
    }

    private func seen(_ info: AppModel.ImageInfo) -> some View {
        let f = info.features
        var people: [String] = []
        if f.personCount > 0 { people.append(f.personCount == 1 ? "1 person" : "\(f.personCount) people") }
        if f.faceCount > 0 { people.append(f.faceCount == 1 ? "1 face" : "\(f.faceCount) faces") }
        if f.isScreenshotOrDocument { people.append("screenshot or document") }
        let labels = (info.details?.labels ?? f.labels.map { ($0, 0) })
            .filter { !ImageFeatures.peopleLabels.contains($0.0) || f.personCount == 0 }
        var seenNames = Set<String>()
        let unique = labels.filter { seenNames.insert(LabelResolver.displayName($0.0)).inserted }.prefix(14)
        return Section("Seen in it") {
            if people.isEmpty && unique.isEmpty {
                Text("Nothing recognised.").font(.sans(13)).foregroundStyle(Theme.muted)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(people, id: \.self) { Tag(text: $0, symbol: "person") }
                    ForEach(Array(unique), id: \.0) { label, confidence in
                        Tag(text: LabelResolver.displayName(label))
                            .help(confidence > 0 ? "Vision: \(percent(confidence)) sure" : "")
                    }
                }
            }
        }
    }

    private func recognisedText(_ text: String) -> some View {
        Section("Text in the image") {
            Text(text)
                .font(.mono(12))
                .foregroundStyle(Theme.ink)
                .lineLimit(12)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var actions: some View {
        FlowLayout(spacing: 10, lineSpacing: 10) {
            Button("Find similar") { model.findSimilar(id) }
                .buttonStyle(AccentOutlineButtonStyle())
                .fixedSize()
            Button("Show in Finder") { model.reveal([id]) }
                .buttonStyle(AccentOutlineButtonStyle())
                .fixedSize()
            ExportMenu(ids: [id])
        }
    }

    private func totalShare(_ p: [PaletteEntry]) -> Float { p.reduce(0) { $0 + $1.share } }

    private func topBuckets(_ shares: [Float]) -> [(ColourBucket, Float)] {
        ColourProfile(bucketShares: shares, palette: []).rankedBuckets
            .filter { $0.share >= 0.05 }
            .prefix(5)
            .map { ($0.bucket, $0.share) }
    }
}

private func percent(_ v: Float) -> String { "\(Int((v * 100).rounded()))%" }

/// "Export ⌄": to a folder or as a zip.
private struct ExportMenu: View {
    @Environment(AppModel.self) private var model
    let ids: [UUID]

    var body: some View {
        Menu {
            Button("Export to Folder…") { model.export(.folder, ids: ids) }
            Button("Export as Zip…") { model.export(.zip, ids: ids) }
        } label: {
            HStack(spacing: 6) {
                Text("Export")
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(AccentOutlineButtonStyle())
        .fixedSize()
        .disabled(model.exportProgress != nil)
    }
}

// MARK: - Several images

private struct SelectionDetails: View {
    @Environment(AppModel.self) private var model
    let hits: [SearchIndex.Hit]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(hits.prefix(9)) { hit in
                    Color.clear
                        .aspectRatio(1, contentMode: .fit)
                        .overlay { Thumbnail(id: hit.id, aspect: 1, contentMode: .fill) }
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(hits.count.grouped) images selected")
                    .font(.sans(15, .semibold))
                    .foregroundStyle(Theme.ink)
                if hits.count > 9 {
                    Text("and \((hits.count - 9).grouped) more")
                        .font(.mono(11))
                        .foregroundStyle(Theme.muted)
                }
            }
            Section("Colours") {
                FlowLayout(spacing: 6) {
                    ForEach(commonBuckets, id: \.self) { bucket in
                        HStack(spacing: 6) {
                            SwatchDot(bucket: bucket, size: 10)
                            Text(bucket.rawValue).font(.sans(12, .medium)).foregroundStyle(Theme.ink)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(Theme.field, in: Capsule())
                    }
                }
            }
            FlowLayout(spacing: 10, lineSpacing: 10) {
                Button("Show in Finder") { model.reveal(hits.map(\.id)) }
                    .buttonStyle(AccentOutlineButtonStyle())
                    .fixedSize()
                Button("Copy") { model.copySelection() }
                    .buttonStyle(AccentOutlineButtonStyle())
                    .fixedSize()
                ExportMenu(ids: hits.map(\.id))
            }
        }
    }

    /// The colours most of the selection shares: the average bucket shares, top five.
    private var commonBuckets: [ColourBucket] {
        guard let first = hits.first else { return [] }
        var sum = [Float](repeating: 0, count: first.features.bucketShares.count)
        for hit in hits { for i in sum.indices where i < hit.features.bucketShares.count { sum[i] += hit.features.bucketShares[i] } }
        let avg = sum.map { $0 / Float(hits.count) }
        return ColourProfile(bucketShares: avg, palette: []).rankedBuckets
            .filter { $0.share >= 0.05 }.prefix(5).map(\.bucket)
    }
}

// MARK: - Pieces

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).sectionLabel().accessibilityAddTraits(.isHeader)
            content
        }
    }
}

private struct Tag: View {
    let text: String
    var symbol: String?

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(Theme.ink)
            }
            Text(text).font(.sans(12, .medium)).foregroundStyle(Theme.ink)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Theme.field, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// "Brightness ▬▬▬▬──── 62%"
private struct Meter: View {
    let title: String
    let value: Float
    var note: String?

    var body: some View {
        let v = min(max(value, 0), 1)
        HStack(spacing: 10) {
            Text(title).font(.sans(12)).foregroundStyle(Theme.muted).frame(width: 76, alignment: .leading)
            MatchBar(value: CGFloat(v))
            Text(note ?? percent(v))
                .font(.mono(11))
                .foregroundStyle(note == nil ? Theme.muted : Theme.accent)
                .frame(width: 64, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(percent(v))\(note.map { ", \($0)" } ?? "")")
    }
}

// MARK: - Preview loading

struct ExifSummary: Sendable {
    var taken: Date?
    var camera: String?
    var settings: String?
}

enum PreviewLoader {
    /// A display-size preview of the original plus a few EXIF facts.
    static func load(_ url: URL, maxPixel: Int) -> (image: CGImage?, exif: ExifSummary?) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return (nil, nil) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        return (image, exif(from: props))
    }

    private static func exif(from props: [CFString: Any]) -> ExifSummary? {
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        var s = ExifSummary()
        if let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            s.taken = f.date(from: raw)
        }
        let make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces)
        let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
        if let model {
            // "Canon Canon EOS R5" → "Canon EOS R5"
            s.camera = make.map { model.hasPrefix($0) ? model : "\($0) \(model)" } ?? model
        }
        var parts: [String] = []
        if let focal = exif[kCGImagePropertyExifFocalLength] as? Double { parts.append("\(Int(focal.rounded())) mm") }
        if let f = exif[kCGImagePropertyExifFNumber] as? Double { parts.append(String(format: "ƒ/%.1f", f)) }
        if let t = exif[kCGImagePropertyExifExposureTime] as? Double, t > 0 {
            parts.append(t >= 1 ? String(format: "%.1f s", t) : "1/\(Int((1 / t).rounded())) s")
        }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { parts.append("ISO \(iso)") }
        if !parts.isEmpty { s.settings = parts.joined(separator: " · ") }
        return s.taken == nil && s.camera == nil && s.settings == nil ? nil : s
    }
}
