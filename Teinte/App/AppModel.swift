import AppKit
import Foundation
import Observation
import SwiftData
import TeinteCore

/// What the sidebar has selected. It sets the search scope, or restores a saved look.
enum SidebarItem: Hashable {
    case all, recent, look(UUID), folder(UUID)
}

/// App state. Everything heavy happens in actors; this only holds results.
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
    var showDebug = false
    var scope: SearchScope = .all

    // Chrome
    var selection: SidebarItem = .all
    var viewMode: ViewMode = .grid
    var sidebarVisible = true
    var looks: [LookInfo] = []
    var stats = SearchIndex.Stats()
    /// The user chose to browse while a large import runs.
    var importDismissed = false
    /// Bumped to move keyboard focus to the search bar (⌘K).
    var focusSearchToken = 0
    /// Debug snapshots of the import screen.
    var forceImportScreen = false
    /// Bumped to open the "Save as look" form (⌘S).
    var saveLookRequest = 0

    /// Images added in the last 7 days count as "Recently added".
    static let recentWindow: TimeInterval = 7 * 24 * 3600

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
            container = try ModelContainer(for: WatchedFolder.self, ImageRecord.self, SavedLook.self,
                                           configurations: config)
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
        await refreshLooks()
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
        await refreshStats()
    }

    private func refreshStats() async {
        guard let index else { return }
        stats = await index.stats(recentSince: Date(timeIntervalSinceNow: -Self.recentWindow))
    }

    // MARK: - Import screen

    /// The big "looking at your images" screen: when there are no folders, while the first import runs,
    /// and while a large import (> 200 images to go) runs, unless dismissed.
    var showsImportScreen: Bool {
        if folders.isEmpty || forceImportScreen { return true }
        let remaining = progress.total - progress.done
        guard progress.isRunning || remaining > 0 else { return false }
        if stats.total == 0 { return true }
        return remaining > 200 && !importDismissed
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
            importDismissed = false
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
        if selection == .folder(id) { select(.all) }
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

    /// The search bar's text. Setting it from the UI re-parses; looks set `query` directly.
    var queryText: String {
        get { query }
        set {
            guard newValue != query else { return }
            query = newValue
            if case .look = selection { selection = .all; scope = .all }
            queryChanged()
        }
    }

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
        if case .look = selection { selection = .all; scope = .all }
        runSearch()
    }

    func clearSearch() {
        parseTask?.cancel()
        query = ""
        parsed = nil
        active = .empty
        chipsEdited = false
        if case .look = selection { selection = .all; scope = .all }
        runSearch()
    }

    /// "of 1,240 images": the size of the current scope.
    var scopeTotal: Int {
        switch selection {
        case .all, .look: stats.total
        case .recent: stats.recent
        case .folder(let id): stats.perFolder[id] ?? 0
        }
    }

    var hasSearch: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty || !active.isEmpty }

    /// Parser and ranking details, shown when View › Show Analysis Details is on.
    var debugLine: String? {
        guard showDebug else { return nil }
        var lines = ["parser: \(parserUsed.isEmpty ? parserStatus : parserUsed)"
            + (parsed != nil ? String(format: " · %.0f ms", parseMilliseconds) : "")]
        if let rules = ruleParse, parserUsed != "rules" {
            lines.append("rules would say: \(rules.summary.isEmpty ? "—" : rules.summary)")
        }
        if !hardLabels.isEmpty { lines.append("label filters: \(hardLabels.joined(separator: ", "))") }
        lines.append("ranking text: \(rankingText ?? "—")")
        lines.append("embeddings: \(embedderStatus)" + String(format: " · filter + rank %.1f ms", searchMilliseconds))
        if let parseError { lines.append(parseError) }
        return lines.joined(separator: "\n")
    }

    // MARK: - Sidebar

    func select(_ item: SidebarItem) {
        selection = item
        switch item {
        case .all: scope = .all
        case .recent: scope = .addedSince(Date(timeIntervalSinceNow: -Self.recentWindow))
        case .folder(let id): scope = .folder(id)
        case .look(let id):
            guard let look = looks.first(where: { $0.id == id }) else { return }
            parseTask?.cancel()
            scope = .all
            query = look.query
            parsed = look.filters
            active = look.filters
            chipsEdited = look.chipsEdited
            parserUsed = "saved look"
        }
        runSearch()
    }

    // MARK: - Saved looks

    /// A default name from the chips: "Mostly blue, with people".
    var suggestedLookName: String {
        let text = active.chips.map(\.title).joined(separator: ", ")
        let base = text.isEmpty ? query : text
        return base.prefix(1).uppercased() + base.dropFirst()
    }

    var canSaveLook: Bool { !active.isEmpty || !query.trimmingCharacters(in: .whitespaces).isEmpty }

    func saveLook(named name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSaveLook else { return }
        do {
            let look = try await store.addLook(name: trimmed.isEmpty ? suggestedLookName : trimmed,
                                               query: query, filters: active, chipsEdited: chipsEdited)
            await refreshLooks()
            selection = .look(look.id)
        } catch {
            message = "Couldn't save the look: \(error.localizedDescription)"
        }
    }

    func renameLook(_ id: UUID, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? await store.renameLook(id, to: trimmed)
        await refreshLooks()
    }

    func deleteLook(_ id: UUID) async {
        try? await store.deleteLook(id)
        if selection == .look(id) { selection = .all }
        await refreshLooks()
    }

    func moveLook(_ id: UUID, by offset: Int) async {
        var ids = looks.map(\.id)
        guard let i = ids.firstIndex(of: id) else { return }
        let j = i + offset
        guard ids.indices.contains(j) else { return }
        ids.swapAt(i, j)
        try? await store.reorderLooks(ids)
        await refreshLooks()
    }

    private func refreshLooks() async {
        looks = (try? await store.looks()) ?? []
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
