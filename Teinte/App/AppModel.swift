import AppKit
import Foundation
import Observation
import SwiftData
import TeinteCore

/// App state for the Phase 1 prototype. Everything heavy happens in actors; this only holds results.
@MainActor
@Observable
final class AppModel {
    struct FolderRow: Identifiable, Hashable {
        var info: FolderInfo
        var available: Bool
        var count: Int
        var id: UUID { info.id }
    }

    // Library
    var folders: [FolderRow] = []
    var progress: AnalysisProgress = .idle
    var embedderStatus = "loading…"
    var parserStatus = ""
    var message: String?

    // Search
    var query = ""
    /// What the parser returned for `query`.
    var parsed: QueryFilters?
    /// `parsed` minus chips the user removed.
    var active: QueryFilters = .empty
    var chipsEdited = false
    var parserUsed = ""
    var ruleParse: QueryFilters?
    var parseError: String?
    var rankingText: String?
    var hardLabels: [String] = []
    var hits: [SearchIndex.Hit] = []
    var total = 0
    var parseMilliseconds: Double = 0
    var searchMilliseconds: Double = 0
    var showDebug = true
    var scope: SearchScope = .all

    // Services
    let thumbnails = ThumbnailCache()
    private let access = FolderAccess()
    private let container: ModelContainer
    private let store: LibraryStore
    private var index: SearchIndex!
    private var queue: AnalysisQueue!
    private var embedder: EmbeddingModel?
    private var fmParser: FoundationModelsParser?
    private var ruleParser = RuleBasedParser()
    private var resolver = LabelResolver.empty
    private var taxonomy: Set<String> = []

    private var parseTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var lastBatchRefresh = Date.distantPast

    init() {
        let support = Self.supportDirectory
        let config = ModelConfiguration(url: support.appendingPathComponent("Library.store"))
        do {
            container = try ModelContainer(for: WatchedFolder.self, ImageRecord.self, configurations: config)
        } catch {
            fatalError("Couldn't open the library database: \(error)")
        }
        store = LibraryStore(modelContainer: container)
        Task { await bootstrap() }
    }

    static var supportDirectory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Teinte", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Startup

    private func bootstrap() async {
        // Embedding model.
        switch SigLIPEmbedder.loadFromBundle() {
        case .success(let e):
            embedder = e
            embedderStatus = "\(e.modelID) · \(e.dimension)-d"
        case .failure(let error):
            embedderStatus = "no embedding model (\(error)) — run script/convert-siglip.py"
        }
        let dimension = embedder?.dimension ?? 1
        let embeddingStore = embedder.flatMap { e in
            try? EmbeddingStore(url: Self.supportDirectory.appendingPathComponent("embeddings.bin"),
                                dimension: e.dimension, modelID: e.modelID)
        }
        index = SearchIndex(dimension: dimension, embeddings: embeddingStore)

        // Parser.
        if FoundationModelsParser.isAvailable {
            let p = FoundationModelsParser()
            p.prewarm()
            fmParser = p
            parserStatus = "Foundation Models"
        } else {
            parserStatus = "rules (Foundation Models: \(FoundationModelsParser.availability))"
        }

        let queue = AnalysisQueue(
            store: store, access: access, index: index, embedder: embedder, thumbnails: thumbnails,
            onProgress: { [weak self] p in Task { @MainActor in self?.progress = p } },
            onBatch: { [weak self] in Task { @MainActor in self?.batchFinished() } })
        self.queue = queue

        // Folders: resolve bookmarks, start access.
        let infos = (try? await store.folders()) ?? []
        for info in infos {
            let url = access.open(info) { [store] data, url in
                Task { try? await store.updateBookmark(folderID: info.id, bookmark: data, path: url.path) }
            }
            if url == nil { await index.setAvailability(folderID: info.id, available: false) }
        }

        // Index from the database.
        let features = (try? await store.analysedFeatures()) ?? []
        let missing = await index.load(features)
        if embedder != nil, !missing.isEmpty { try? await store.markPending(missing) }
        for info in infos where !access.isAvailable(info.id) {
            await index.setAvailability(folderID: info.id, available: false)
        }

        taxonomy = await Task.detached { VisionAnalyzer.taxonomy() }.value
        await refreshVocabulary()
        await refreshFolders()
        runSearch()

        // Catch changes made while the app was closed, then analyse what's pending.
        for info in infos where access.isAvailable(info.id) { await rescan(info.id) }
        await queue.start()
    }

    private func refreshVocabulary() async {
        let seen = (try? await store.labelVocabulary()) ?? []
        resolver = LabelResolver(vocabulary: taxonomy.union(seen))
        ruleParser = RuleBasedParser(labelResolver: resolver)
    }

    private func refreshFolders() async {
        let infos = (try? await store.folders()) ?? []
        var rows: [FolderRow] = []
        for info in infos {
            let count = (try? await store.imageCount(folderID: info.id)) ?? 0
            rows.append(FolderRow(info: info, available: access.isAvailable(info.id), count: count))
        }
        folders = rows
        if let counts = try? await store.counts() {
            progress.done = counts.done
            progress.total = counts.total
        }
    }

    private func batchFinished() {
        // Show new results while analysis runs, but not more than every 2 s.
        guard Date().timeIntervalSince(lastBatchRefresh) > 2 else { return }
        lastBatchRefresh = .now
        Task {
            await refreshVocabulary()
            await refreshFolders()
            runSearch()
        }
    }

    // MARK: - Folders

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders with images. Teinte only reads them."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { Task { await addFolder(url) } }
    }

    func addFolder(_ url: URL) async {
        let existing = folders.compactMap { access.folderURL($0.id) }
        switch FolderBookmark.overlap(of: url, with: existing) {
        case .same, .insideExisting(_):
            message = "\(url.lastPathComponent) is already in your library."
            return
        case .containsExisting, .none:
            break // Phase 2 merges contained folders; for now they simply both stay.
        }
        do {
            let bookmark = try FolderBookmark.create(for: url)
            let info = try await store.addFolder(displayName: url.lastPathComponent, bookmark: bookmark, path: url.path)
            access.register(info.id, url: url)
            await refreshFolders()
            await rescan(info.id)
            await queue.start()
        } catch {
            message = "Couldn't add \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func removeFolder(_ id: UUID) async {
        let removed = (try? await store.removeFolder(id)) ?? []
        await index.remove(removed)
        removed.forEach(thumbnails.remove)
        access.close(id)
        await refreshFolders()
        runSearch()
    }

    private func rescan(_ folderID: UUID) async {
        guard let url = access.folderURL(folderID) else { return }
        let files = await Task.detached(priority: .utility) { FolderScanner.scan(url) }.value
        if let outcome = try? await store.reconcile(folderID: folderID, files: files) {
            await index.remove(outcome.removed)
            outcome.removed.forEach(thumbnails.remove)
        }
        await refreshFolders()
    }

    func fileURL(for hit: SearchIndex.Hit) async -> URL? {
        guard let details = try? await store.details([hit.id])[hit.id] else { return nil }
        return access.fileURL(folderID: details.folderID, relativePath: details.relativePath)
    }

    func details(for id: UUID) async -> LibraryStore.Details? {
        try? await store.details([id])[id]
    }

    // MARK: - Search

    /// Called on every keystroke. Debounced; cancels a parse in flight.
    func queryChanged() {
        parseTask?.cancel()
        let sentence = query.trimmingCharacters(in: .whitespacesAndNewlines)
        parseTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await parse(sentence)
        }
    }

    private func parse(_ sentence: String) async {
        chipsEdited = false
        parseError = nil
        guard !sentence.isEmpty else {
            parsed = nil; active = .empty; ruleParse = nil; parserUsed = ""
            runSearch(); return
        }
        let start = Date()
        let rules = ruleParser.parseSync(sentence)
        var result = rules
        var used = ruleParser.name
        if let fmParser {
            do {
                result = try await fmParser.parse(sentence)
                used = fmParser.name
            } catch {
                parseError = "Foundation Models failed (\(error.localizedDescription)); used rules"
            }
        }
        guard !Task.isCancelled else { return }
        parseMilliseconds = Date().timeIntervalSince(start) * 1000
        parsed = result
        active = result
        ruleParse = rules
        parserUsed = used
        runSearch()
    }

    func remove(_ chip: FilterChip) {
        active = active.removing(chip)
        chipsEdited = true
        runSearch()
    }

    func runSearch() {
        guard let index else { return }
        searchTask?.cancel()
        let filters = active
        let resolved = ResolvedQuery(filters: filters, resolver: resolver)
        hardLabels = resolved.hardLabels

        // Ranking text: free text (+ unresolved labels); else the whole sentence, unless the user edited the chips.
        var text: String?
        if let t = resolved.rankingText {
            text = "a photo of \(t)"
        } else if !chipsEdited, !query.trimmingCharacters(in: .whitespaces).isEmpty {
            text = query
        }
        rankingText = text
        let embedder = embedder
        let scope = scope
        let calibration = embedder?.calibration ?? .generic

        searchTask = Task {
            var vector: [Float]?
            if let text, let embedder { vector = try? await embedder.embed(text: text) }
            guard !Task.isCancelled else { return }
            let outcome = await index.search(resolved, vector: vector, scope: scope, calibration: calibration)
            guard !Task.isCancelled else { return }
            hits = outcome.hits
            total = outcome.total
            searchMilliseconds = outcome.milliseconds
        }
    }
}
