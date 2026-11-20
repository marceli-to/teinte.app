import AppKit
import SwiftUI
import TeinteCore

/// Search bar and chips on top; the count, then the grid or the list.
struct ResultsView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var resultsFocused: Bool
    @State private var gridColumns = 1

    private var horizontalPadding: CGFloat { model.sidebarVisible ? 40 : 80 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                ResultsHeader()
                if model.debugLine != nil { DebugInfo() }
                if model.hits.isEmpty {
                    EmptyResults()
                } else if model.viewMode == .grid {
                    ResultsGrid(columns: $gridColumns)
                } else {
                    ResultsList()
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.top, 28)
            .padding(.bottom, 40)
            // A click on empty space clears the selection and takes keyboard focus for the arrow keys.
            .background {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { model.clearSelection(); resultsFocused = true }
            }
        }
        .scrollIndicators(.automatic)
        .focusable()
        .focusEffectDisabled()
        .focused($resultsFocused)
        .onChange(of: model.selectedIDs) { if !model.selectedIDs.isEmpty { resultsFocused = true } }
        .onKeyPress(.escape) {
            guard !model.selectedIDs.isEmpty else { return .ignored }
            model.clearSelection()
            return .handled
        }
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            let row = model.viewMode == .grid ? gridColumns : 1
            let offset = switch press.key {
            case .leftArrow: model.viewMode == .grid ? -1 : 0
            case .rightArrow: model.viewMode == .grid ? 1 : 0
            case .upArrow: -row
            default: row
            }
            guard offset != 0 else { return .ignored }
            model.moveFocus(by: offset, extend: press.modifiers.contains(.shift))
            return .handled
        }
        // Results scroll under the search header, which blurs them.
        .safeAreaInset(edge: .top, spacing: 0) { header }
    }

    private var header: some View {
        VStack(spacing: 14) {
            SearchBar()
                .frame(maxWidth: 760)
            if model.parsed != nil || model.hasSearch {
                ChipsRow()
                    .frame(maxWidth: 760)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, horizontalPadding)
        .animation(.easeOut(duration: 0.18), value: model.parsed != nil || model.hasSearch)
        .background { HeaderBackdrop() }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

/// Translucent ground over a blur of whatever scrolls underneath.
struct HeaderBackdrop: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Rectangle().fill(Theme.ground.opacity(0.62))
        }
    }
}

// MARK: - Header

struct ResultsHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(model.hits.count.grouped)
                .font(.display(40))
                .foregroundStyle(Theme.ink)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.2), value: model.hits.count)
            Text("of \(model.scopeTotal.grouped) images")
                .font(.sans(14, .regular))
                .foregroundStyle(Theme.muted)
            Spacer(minLength: 16)
            if model.selectedIDs.isEmpty {
                Text(hint)
                    .font(.mono(11))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            } else {
                SelectionSummary()
            }
        }
    }

    private var hint: String {
        if model.rankingText == nil { return model.active.isEmpty ? "newest first" : "strongest colour match first" }
        return model.viewMode == .grid ? "sorted by how well they match" : "why each one matched"
    }
}

/// "3 selected · Deselect" on the right of the count.
struct SelectionSummary: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Text("\(model.selectedIDs.count.grouped) selected")
                .font(.mono(11))
                .foregroundStyle(Theme.ink)
                .contentTransition(.numericText())
            Button("Deselect") { model.clearSelection() }
                .buttonStyle(.plain)
                .font(.mono(11))
                .foregroundStyle(Theme.muted)
                .help("Deselect all (Esc)")
        }
        .animation(.easeOut(duration: 0.15), value: model.selectedIDs.count)
    }
}

struct DebugInfo: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Text(model.debugLine ?? "")
            .font(.mono(11))
            .foregroundStyle(Theme.muted)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Theme.selection, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct EmptyResults: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            Text(model.scopeTotal == 0 ? "No images here yet." : "Nothing matches.")
                .font(.sans(20, .semibold))
                .foregroundStyle(Theme.ink)
            if model.scopeTotal > 0 {
                Text(model.active.chips.isEmpty ? "Try describing it differently." : "Try removing a filter.")
                    .font(.body)
                    .foregroundStyle(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Grid

struct ResultsGrid: View {
    @Environment(AppModel.self) private var model
    /// How many columns fit, for the up and down arrow keys.
    @Binding var columns: Int

    static let minimum: CGFloat = 200
    static let spacing: CGFloat = 18

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.minimum), spacing: Self.spacing, alignment: .top)],
                  alignment: .leading, spacing: 26) {
            ForEach(model.hits) { hit in
                GridTile(hit: hit, showDebug: model.showDebug, selected: model.selectedIDs.contains(hit.id),
                         dimmed: !model.selectedIDs.isEmpty && !model.selectedIDs.contains(hit.id))
                    .id(hit.id)
            }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
            columns = max(1, Int((width + Self.spacing) / (Self.minimum + Self.spacing)))
        }
    }
}

private struct GridTile: View {
    @Environment(AppModel.self) private var model
    let hit: SearchIndex.Hit
    let showDebug: Bool
    let selected: Bool
    let dimmed: Bool
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // A 4:3 cell filled by the image (cropped), as in the mockup, so rows stay even.
            Color.clear
                .aspectRatio(4 / 3, contentMode: .fit)
                .overlay {
                    Thumbnail(id: hit.id, aspect: 4 / 3, contentMode: .fill)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Theme.ink.opacity(hovering ? 0.25 : 0.06), lineWidth: 1)
                }

                .overlay(alignment: .bottomLeading) {
                    if showDebug { DebugOverlay(hit: hit) }
                }
            HStack(spacing: 8) {
                Text(hit.features.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Text(hit.matchText)
            }
            .font(.mono(12))
            .foregroundStyle(Theme.ink)
        }
        // With a selection, the others step back.
        .opacity(dimmed ? 0.35 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.15), value: dimmed)
        .resultInteractions(hit: hit)
        .help(hit.features.fileName)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hit.accessibilityText)
        .accessibilityAddTraits(selected ? [.isImage, .isSelected] : .isImage)
    }
}

/// Click, ⌘-click, ⇧-click, double-click and the context menu, shared by grid tiles and list rows.
private struct ResultInteractions: ViewModifier {
    @Environment(AppModel.self) private var model
    let hit: SearchIndex.Hit

    func body(content: Content) -> some View {
        content
            // Selection happens on the first click; the double-click is recognised alongside it.
            .onTapGesture(count: 2) { model.showDetails(hit.id) }
            .simultaneousGesture(TapGesture().onEnded {
                let flags = NSEvent.modifierFlags
                model.click(hit.id, kind: flags.contains(.command) ? .toggle : flags.contains(.shift) ? .extend : .plain)
            })
            .contextMenu {
                Button("Show Details") { model.showDetails(hit.id) }
                Divider()
                Button(targets.count > 1 ? "Show \(targets.count) in Finder" : "Show in Finder") {
                    model.reveal(targets)
                }
                Button(targets.count > 1 ? "Copy \(targets.count) Images" : "Copy Image") {
                    if !model.selectedIDs.contains(hit.id) { model.click(hit.id, kind: .plain) }
                    model.copySelection()
                }
            }
    }

    /// A context menu on a selected image acts on the whole selection.
    private var targets: [UUID] {
        model.selectedIDs.contains(hit.id) ? model.selectedHits.map(\.id) : [hit.id]
    }
}

extension View {
    fileprivate func resultInteractions(hit: SearchIndex.Hit) -> some View {
        modifier(ResultInteractions(hit: hit))
    }
}

/// A cached thumbnail, with a quiet placeholder of the right shape while it loads.
struct Thumbnail: View {
    @Environment(AppModel.self) private var model
    let id: UUID
    let aspect: CGFloat
    var contentMode: ContentMode = .fit
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: contentMode == .fit ? .fit : .fill)
            } else {
                Rectangle().fill(Theme.placeholder)
                    .aspectRatio(aspect, contentMode: contentMode)
            }
        }
        .task(id: id) {
            let cache = model.thumbnails
            let loaded = await Task.detached(priority: .userInitiated) { cache.image(for: id) }.value
            withAnimation(.easeOut(duration: 0.15)) { image = loaded }
        }
    }
}

private struct DebugOverlay: View {
    let hit: SearchIndex.Hit

    var body: some View {
        let f = hit.features
        let colours = ColourProfile(bucketShares: f.bucketShares, palette: []).rankedBuckets.prefix(3)
            .map { "\($0.bucket.rawValue) \(Int(($0.share * 100).rounded()))%" }.joined(separator: " ")
        VStack(alignment: .leading, spacing: 1) {
            Text(colours)
            Text("people \(f.personCount) · faces \(f.faceCount)\(f.hasText ? " · text" : "")\(f.isUtility ? " · utility" : "")")
            Text(String(format: "L %.2f · ctr %.2f · sat %.3f · warm %.3f%@", f.look.brightness, f.look.contrast,
                        f.look.saturation, f.look.warmth, f.look.isBlackAndWhite ? " · b&w" : ""))
            if let a = f.aesthetics { Text(String(format: "aesthetics %.2f", a)) }
            if !f.recognizedText.isEmpty {
                Text("“\(f.recognizedText.replacingOccurrences(of: "\n", with: " ").prefix(40))”")
            }
            Text(f.labels.prefix(4).map(LabelResolver.displayName).joined(separator: ", "))
            Text(String(format: "cos %.3f", hit.score))
        }
        .font(.mono(9))
        .padding(5)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
        .foregroundStyle(.white)
        .padding(6)
    }
}

// MARK: - List

/// IMAGE · COLOURS · SEEN IN IT · SIZE · MATCH. Explains why each image matched.
struct ResultsList: View {
    @Environment(AppModel.self) private var model
    @State private var width: CGFloat = 900

    var body: some View {
        let columns = ListColumns(width: width)
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
            HStack(spacing: 0) {
                Text("Image").frame(width: columns.image, alignment: .leading)
                Text("Colours").frame(width: columns.colours, alignment: .leading)
                Text("Seen in it").frame(width: columns.seen, alignment: .leading)
                Text("Size").frame(width: columns.size, alignment: .leading)
                Text("Match").frame(maxWidth: .infinity, alignment: .trailing)
            }
            .sectionLabel()
            .padding(.bottom, 14)
            .accessibilityHidden(true)
            Rectangle().fill(Theme.line).frame(height: 1)
            ForEach(model.hits) { hit in
                ListRow(hit: hit, columns: columns, matchedBucket: matchedBucket,
                        selected: model.selectedIDs.contains(hit.id))
                Rectangle().fill(Theme.line).frame(height: 1)
            }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
    }

    /// The colour the query asked for; the list shows its share. Otherwise each image's top colour.
    private var matchedBucket: ColourBucket? {
        model.active.colours.first { $0.mode != .without }?.bucket
    }
}

struct ListColumns {
    let image, colours, seen, size: CGFloat

    init(width: CGFloat) {
        image = width * 0.29
        colours = width * 0.20
        seen = width * 0.225
        size = width * 0.16
    }
}

private struct ListRow: View {
    @Environment(AppModel.self) private var model
    let hit: SearchIndex.Hit
    let columns: ListColumns
    let matchedBucket: ColourBucket?
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        let f = hit.features
        HStack(spacing: 0) {
            HStack(spacing: 16) {
                Thumbnail(id: hit.id, aspect: f.aspect, contentMode: .fill)
                    .frame(width: 56, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Text(f.fileName)
                    .font(.sans(13, .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(width: columns.image, alignment: .leading)

            HStack(spacing: 14) {
                HStack(spacing: 2) {
                    ForEach(Array(f.palette.prefix(3).enumerated()), id: \.offset) { _, entry in
                        SwatchDot(oklab: entry.colour, size: 18)
                    }
                }
                .frame(width: 58, alignment: .leading)
                Text(colourShare)
                    .font(.mono(12))
                    .foregroundStyle(Theme.muted)
            }
            .frame(width: columns.colours, alignment: .leading)

            Text(f.seenInIt)
                .font(.sans(13, .regular))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .padding(.trailing, 16)
                .frame(width: columns.seen, alignment: .leading)

            Text(verbatim: "\(f.pixelWidth) × \(f.pixelHeight)")
                .font(.mono(12))
                .foregroundStyle(Theme.muted)
                .frame(width: columns.size, alignment: .leading)

            HStack(spacing: 14) {
                Spacer(minLength: 0)
                if let m = hit.match {
                    MatchBar(value: CGFloat(m)).frame(width: 56)
                }
                Text(hit.matchText)
                    .font(.mono(12, .medium))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 40, alignment: .trailing)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: 60)
        .background(Theme.selection.opacity(selected ? 1 : hovering ? 0.6 : 0))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .resultInteractions(hit: hit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(hit.accessibilityText). \(colourShare). \(f.pixelWidth) by \(f.pixelHeight). Match \(hit.matchText)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var colourShare: String {
        let f = hit.features
        let bucket = matchedBucket
            ?? ColourProfile(bucketShares: f.bucketShares, palette: []).rankedBuckets.first?.bucket
        guard let bucket else { return "" }
        return "\(Int((f.share(of: bucket) * 100).rounded()))% \(bucket.rawValue)"
    }
}

struct MatchBar: View {
    let value: CGFloat

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.line)
                Capsule().fill(Theme.accent).frame(width: geo.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

// MARK: - Display helpers

extension SearchIndex.Hit {
    var matchText: String {
        guard let match else { return "—" }
        return "\(Int((match * 100).rounded()))%"
    }

    var accessibilityText: String {
        let seen = features.seenInIt
        return seen.isEmpty ? features.fileName : "\(features.fileName): \(seen.replacingOccurrences(of: " · ", with: ", "))"
    }
}

extension ImageFeatures {
    static let peopleLabels: Set<String> = ["people", "person", "adult", "child", "baby", "crowd", "human"]

    var aspect: CGFloat {
        guard pixelWidth > 0, pixelHeight > 0 else { return 4 / 3 }
        return CGFloat(pixelWidth) / CGFloat(pixelHeight)
    }

    /// "2 people · water · jetty"
    var seenInIt: String {
        var parts: [String] = []
        if personCount > 0 { parts.append(personCount == 1 ? "1 person" : "\(personCount) people") }
        // "1 person · people · adult" says the same thing three times.
        var seen: Set<String> = personCount > 0 ? Self.peopleLabels : []
        for label in labels {
            let name = LabelResolver.displayName(label)
            guard seen.insert(name).inserted else { continue }
            parts.append(name)
            if parts.count >= 3 { break }
        }
        return parts.joined(separator: " · ")
    }
}
