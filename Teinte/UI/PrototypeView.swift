import AppKit
import SwiftUI
import TeinteCore

/// Phase 1: deliberately plain. A search field, the parsed filters as text, and a grid with debug details.
/// The designed UI replaces this in Phase 2.
struct PrototypeView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List {
                Section("Library") {
                    Button { model.scope = .all; model.runSearch() } label: {
                        Label("All images", systemImage: "photo.on.rectangle")
                    }
                    .buttonStyle(.plain)
                }
                Section("Folders") {
                    ForEach(model.folders) { f in
                        HStack {
                            Button { model.scope = .folder(f.id); model.runSearch() } label: {
                                VStack(alignment: .leading) {
                                    Text(f.info.displayName)
                                    Text(f.available ? "\(f.count) images" : "unavailable")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            Spacer()
                        }
                        .contextMenu {
                            Button("Remove from Library") { Task { await model.removeFolder(f.id) } }
                        }
                    }
                    Button("Add Folder…") { model.chooseFolder() }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            VStack(alignment: .leading, spacing: 12) {
                statusBar
                TextField("Describe what you're looking for, e.g. blue images with people", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                    .focused($searchFocused)
                    .onChange(of: model.query) { model.queryChanged() }
                parsedPanel
                Divider()
                grid
            }
            .padding()
        }
        .onAppear { searchFocused = true }
        .alert("Teinte", isPresented: .constant(model.message != nil)) {
            Button("OK") { model.message = nil }
        } message: { Text(model.message ?? "") }
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            for url in folders { Task { await model.addFolder(url) } }
            return !folders.isEmpty
        }
    }

    private var statusBar: some View {
        HStack(spacing: 16) {
            let p = model.progress
            if p.total > 0 {
                if p.isRunning {
                    ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                        .frame(width: 160)
                    Text("Analysing \(p.done) of \(p.total)")
                    if let s = p.remainingSeconds {
                        Text(String(format: "%.1f img/s · ~%@ left", p.imagesPerSecond, Self.duration(s)))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("\(p.done) of \(p.total) analysed")
                }
            } else {
                Text("Add a folder to start (⌘O or drop it here).")
            }
            Spacer()
            Toggle("Debug", isOn: Binding(get: { model.showDebug }, set: { model.showDebug = $0 }))
                .toggleStyle(.checkbox)
        }
        .font(.callout.monospaced())
    }

    @ViewBuilder private var parsedPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.parsed != nil {
                HStack(spacing: 6) {
                    Text("understood as").foregroundStyle(.secondary)
                    ForEach(model.active.chips) { chip in
                        Button { model.remove(chip) } label: {
                            HStack(spacing: 4) {
                                if case .colour(let c) = chip.kind {
                                    Circle().fill(Color(red: c.bucket.swatch.r, green: c.bucket.swatch.g, blue: c.bucket.swatch.b))
                                        .overlay(Circle().stroke(.black.opacity(0.2), lineWidth: 0.5))
                                        .frame(width: 10, height: 10)
                                }
                                Text(chip.title)
                                Image(systemName: "xmark").font(.caption2)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.background, in: Capsule())
                            .overlay(Capsule().stroke(.separator))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove filter: \(chip.title)")
                    }
                }
            }
            Group {
                Text("parser: \(model.parserUsed.isEmpty ? model.parserStatus : model.parserUsed)"
                     + (model.parsed != nil ? String(format: " · %.0f ms", model.parseMilliseconds) : ""))
                if let rules = model.ruleParse, model.parserUsed != "rules" {
                    Text("rules would say: \(rules.summary.isEmpty ? "—" : rules.summary)")
                }
                if !model.hardLabels.isEmpty { Text("label filters: \(model.hardLabels.joined(separator: ", "))") }
                Text("ranking text: \(model.rankingText ?? "— (sorted by filter strength, newest first)")")
                Text("embeddings: \(model.embedderStatus)")
                if let e = model.parseError { Text(e).foregroundStyle(.red) }
            }
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)

            HStack(alignment: .firstTextBaseline) {
                Text("\(model.hits.count)").font(.system(size: 34, weight: .heavy))
                Text("of \(model.total) images").foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "filter + rank %.1f ms", model.searchMilliseconds))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 16)], spacing: 16) {
                ForEach(model.hits) { hit in
                    Tile(hit: hit, showDebug: model.showDebug)
                }
            }
        }
    }

    static func duration(_ s: Double) -> String {
        s < 90 ? "\(Int(s)) s" : "\(Int(s / 60)) min"
    }
}

private struct Tile: View {
    @Environment(AppModel.self) private var model
    let hit: SearchIndex.Hit
    let showDebug: Bool
    @State private var image: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .bottomLeading) {
                Rectangle().fill(.quaternary)
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .overlay {
                        if let image {
                            Image(decorative: image, scale: 1).resizable().scaledToFill()
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                if showDebug { debugOverlay }
            }
            HStack {
                Text(hit.features.fileName).lineLimit(1).truncationMode(.middle)
                Spacer()
                if let m = hit.match { Text("\(Int((m * 100).rounded()))%") }
            }
            .font(.caption.monospaced())
        }
        .task(id: hit.id) {
            let cache = model.thumbnails
            let id = hit.id
            image = await Task.detached(priority: .userInitiated) { cache.image(for: id) }.value
        }
        .onTapGesture(count: 2) {
            Task { if let url = await model.fileURL(for: hit) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
        }
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var debugOverlay: some View {
        let f = hit.features
        let colours = ColourProfile(bucketShares: f.bucketShares, palette: []).rankedBuckets.prefix(3)
            .map { "\($0.bucket.rawValue) \(Int(($0.share * 100).rounded()))%" }.joined(separator: " ")
        return VStack(alignment: .leading, spacing: 1) {
            Text(colours)
            Text("people \(f.personCount) · faces \(f.faceCount)\(f.hasText ? " · text" : "")")
            Text(f.labels.prefix(4).map(LabelResolver.displayName).joined(separator: ", "))
            Text(String(format: "cos %.3f", hit.score))
        }
        .font(.system(size: 9, design: .monospaced))
        .padding(4)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
        .foregroundStyle(.white)
        .padding(4)
    }

    private var helpText: String {
        let f = hit.features
        return "\(f.fileName)\n\(f.pixelWidth) × \(f.pixelHeight)\nlabels: \(f.labels.joined(separator: ", "))"
    }

    private var accessibilityText: String {
        let f = hit.features
        var parts: [String] = []
        if f.personCount > 0 { parts.append(f.personCount == 1 ? "1 person" : "\(f.personCount) people") }
        parts += f.labels.prefix(2).map(LabelResolver.displayName)
        return "\(f.fileName). " + parts.joined(separator: ", ")
    }
}
