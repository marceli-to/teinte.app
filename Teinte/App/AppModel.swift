import AppKit
import Foundation
import Observation
import SwiftData
import Translation
import UniformTypeIdentifiers
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
    /// `query` in English: what the parser and the embedding model read.
    var englishQuery = ""
    /// How `englishQuery` was made: "", "Apple Translation" or "glossary".
    var translationUsed = ""
    /// The language searches are typed in. German searches are turned into English first.
    var searchLanguage: SearchLanguage = SearchLanguage(
        rawValue: UserDefaults.standard.string(forKey: "searchLanguage") ?? "") ?? .systemDefault() {
        didSet {
            guard searchLanguage != oldValue else { return }
            UserDefaults.standard.set(searchLanguage.rawValue, forKey: "searchLanguage")
            queryChanged()
        }
    }
    /// German → English with Apple's Translation framework (needs a one-time download).
    let translator = QueryTranslator()
    var translationStatus: QueryTranslator.Status = .unknown
    /// Set to ask SwiftUI's `.translationTask` for the language download.
    var translationDownload: TranslationSession.Configuration?
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

    // Selection and details
    /// Selected images, by ID. Kept across searches only for images still in the results.
    var selectedIDs: Set<UUID> = []
    /// The image the details panel shows: the last one clicked.
    var focusedID: UUID?
    /// Where a ⇧-click range starts.
    var selectionAnchor: UUID?
    var inspectorVisible = false
    /// Style-tag prompt embeddings, for the details panel. Computed once.
    var stylePromptVectors: [(StyleTag, [Float])]?
    /// While an export runs: how many of how many files are copied.
    var exportProgress: (done: Int, total: Int)?

    /// Images added in the last 7 days count as "Recently added".
    static let recentWindow: TimeInterval = 7 * 24 * 3600

    // Services
    let thumbnails = ThumbnailCache()
    private let access = FolderAccess()
    private let container: ModelContainer
    private let store: LibraryStore
    private var index: SearchIndex!
    private var queue: AnalysisQueue!
    private var watcher: FolderWatcher?
    private var mountObservers: [NSObjectProtocol] = []
    /// Folders being rescanned, and those that changed again meanwhile.
    private var rescanning: Set<UUID> = []
    private var rescanAgain: Set<UUID> = []
    private var checkingAvailability = false
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

        // Translation (German searches).
        await refreshTranslation()

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
        watcher = FolderWatcher { [weak self] id, change in
            Task { @MainActor in await self?.folderChanged(id, change) }
        }
        observeVolumes()

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

        // Watch first, so nothing that changes during the launch scan is missed. Then catch up on
        // what changed while the app was closed, and analyse what's pending.
        for info in infos { if let url = access.folderURL(info.id) { watcher?.watch(info.id, url: url) } }
        var changed = false
        for info in infos where access.isAvailable(info.id) { changed = await rescan(info.id) || changed }
        if changed { runSearch() }
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
        panel.prompt = String(localized: "Add")
        panel.message = String(localized: "Choose folders with images. Teinte only reads them.")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { Task { await addFolder(url) } }
    }

    func addFolder(_ url: URL) async {
        let existing = folders.compactMap { access.folderURL($0.id) }
        switch FolderBookmark.overlap(of: url, with: existing) {
        case .same, .insideExisting(_):
            message = String(localized: "\(url.lastPathComponent) is already in your library.")
            return
        case .containsExisting, .none:
            break // Phase 2 merges contained folders; for now they simply both stay.
        }
        do {
            let bookmark = try FolderBookmark.create(for: url)
            let info = try await store.addFolder(displayName: url.lastPathComponent, bookmark: bookmark, path: url.path)
            importDismissed = false
            access.register(info.id, url: url)
            watcher?.watch(info.id, url: url)
            await refreshFolders()
            await rescan(info.id)
            await queue.start()
        } catch {
            message = String(localized: "Couldn't add \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    func removeFolder(_ id: UUID) async {
        let removed = (try? await store.removeFolder(id)) ?? []
        await index.remove(removed)
        removed.forEach(thumbnails.remove)
        watcher?.unwatch(id)
        access.close(id)
        if selection == .folder(id) { select(.all) }
        await refreshFolders()
        runSearch()
    }

    /// Compare one folder with the index. Returns whether anything changed.
    @discardableResult
    private func rescan(_ folderID: UUID) async -> Bool {
        guard let url = access.folderURL(folderID) else { return false }
        guard let files = await Task.detached(priority: .utility, operation: { FolderScanner.scan(url) }).value else {
            // The folder itself is gone (unmounted, moved, trashed): never read that as "all images deleted".
            await checkAvailability()
            return false
        }
        guard let outcome = try? await store.reconcile(folderID: folderID, files: files), !outcome.isEmpty else {
            return false
        }
        await index.remove(outcome.removed)
        await index.rename(outcome.renamed)
        outcome.removed.forEach(thumbnails.remove)
        await refreshFolders()
        return true
    }

    // MARK: - Watching

    /// FSEvents reported a change. Rescans are coalesced: one at a time per folder, plus one more
    /// if it changed again meanwhile.
    private func folderChanged(_ id: UUID, _ change: FolderWatcher.Change) async {
        guard folders.contains(where: { $0.id == id }) else { return }
        if change == .root {
            await checkAvailability()
            return
        }
        if rescanning.contains(id) {
            rescanAgain.insert(id)
            return
        }
        rescanning.insert(id)
        var changed = false
        repeat {
            rescanAgain.remove(id)
            changed = await rescan(id) || changed
        } while rescanAgain.contains(id)
        rescanning.remove(id)
        guard changed else { return }
        runSearch()
        await queue.start()
    }

    /// Re-resolve every folder: one that's gone becomes unavailable (its images stay, dimmed);
    /// one that's back (volume mounted, folder moved back) is rescanned and watched again.
    /// A folder that was moved or renamed resolves to its new place through the bookmark.
    private func checkAvailability() async {
        guard !checkingAvailability else { return }
        checkingAvailability = true
        defer { checkingAvailability = false }
        let infos = (try? await store.folders()) ?? []
        var changed = false
        for info in infos {
            if let url = access.folderURL(info.id) {
                if FolderScanner.isReachable(url), !url.pathComponents.contains(".Trash") { continue }
                // Gone from where it was. It may have moved: close and try the bookmark again below.
                watcher?.unwatch(info.id)
                access.close(info.id)
                changed = true
            }
            if let url = access.open(info, refreshed: { [store] data, url in
                Task { try? await store.updateBookmark(folderID: info.id, bookmark: data, path: url.path) }
            }) {
                await index.setAvailability(folderID: info.id, available: true)
                watcher?.watch(info.id, url: url)
                await rescan(info.id)
                changed = true
            } else {
                await index.setAvailability(folderID: info.id, available: false)
            }
        }
        guard changed else { return }
        await refreshFolders()
        runSearch()
        await queue.start()
    }

    private func observeVolumes() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            mountObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.checkAvailability() }
            })
        }
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
        // A "like …" chip isn't part of the sentence; it stays until it's removed or the search is cleared.
        let seed = active.similarTo
        guard !sentence.isEmpty else {
            parsed = nil; active = QueryFilters(similarTo: seed); ruleParse = nil; parserUsed = ""
            runSearch(); return
        }
        let start = Date()
        let (english, translation) = await englishSentence(sentence)
        guard !Task.isCancelled else { return }
        let rules = ruleParser.parseSync(english)
        var result = rules
        var used = ruleParser.name
        if let fmParser {
            do {
                // Foundation Models reads German itself, so it gets the original when only the glossary ran.
                result = try await fmParser.parse(translation == "glossary" ? sentence : english)
                used = fmParser.name
            } catch {
                parseError = "Foundation Models failed (\(error.localizedDescription)); used rules"
            }
        }
        guard !Task.isCancelled else { return }
        parseMilliseconds = Date().timeIntervalSince(start) * 1000
        result.similarTo = seed
        englishQuery = english
        translationUsed = translation
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

    /// "Find similar": rank everything by closeness to this image, keeping the other chips.
    func findSimilar(_ id: UUID) {
        let name = hits.first { $0.id == id }?.features.fileName
        Task {
            let fileName: String
            if let name { fileName = name } else if let f = await index?.features(for: id) { fileName = f.fileName } else { return }
            if case .look = selection { selection = .all; scope = .all }
            active.similarTo = SimilarSeed(id: id, fileName: fileName)
            parsed?.similarTo = active.similarTo
            // The seed isn't in its own results, and the old selection is about a different search.
            clearSelection()
            runSearch()
        }
    }

    func clearSearch() {
        parseTask?.cancel()
        query = ""
        englishQuery = ""
        parsed = nil
        active = .empty
        chipsEdited = false
        if case .look = selection { selection = .all; scope = .all }
        runSearch()
    }

    // MARK: - Language

    /// The sentence in English, and how it got there ("" when it already was).
    /// German goes through Apple Translation when it's installed, otherwise through the glossary.
    func englishSentence(_ sentence: String) async -> (String, String) {
        guard searchLanguage == .german, GermanGlossary.isProbablyGerman(sentence) else { return (sentence, "") }
        if let english = await translator.translate(sentence) { return (english, "Apple Translation") }
        return (GermanGlossary.translate(sentence), "glossary")
    }

    func refreshTranslation() async {
        await translator.refresh()
        translationStatus = translator.status
    }

    /// Asks for the German → English download (the system shows its own prompt).
    func downloadTranslation() {
        translationDownload = TranslationSession.Configuration(source: QueryTranslator.source, target: QueryTranslator.target)
    }

    /// Called by `.translationTask` once the download prompt is done.
    func translationDownloadFinished() async {
        translationDownload = nil
        await refreshTranslation()
        if translationStatus == .installed { queryChanged() }
    }

    /// The glossary was used for this search because translation isn't installed yet.
    var suggestsTranslationDownload: Bool {
        translationUsed == "glossary" && translationStatus == .needsDownload && parsed?.freeText != nil
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
        if !translationUsed.isEmpty { lines.append("english (\(translationUsed)): \(englishQuery)") }
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
            // Ranking reads the sentence in English.
            Task {
                let (english, translation) = await englishSentence(look.query)
                guard selection == item else { return }
                englishQuery = english
                translationUsed = translation
                runSearch()
            }
            return
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
            message = String(localized: "Couldn't save the look: \(error.localizedDescription)")
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

        // Ranking text: the whole sentence ("a photo of red building" keeps the colour on the object),
        // or the parsed parts when the chips were edited or the sentence has a negation.
        let text = RankingPrompt.make(
            sentence: englishQuery, filters: filters, hardLabels: resolved.hardLabels, softLabels: resolved.softLabels,
            sentenceIsCurrent: !chipsEdited)
        rankingText = text
        let embedder = embedder
        let scope = scope
        let calibration = embedder?.calibration ?? .generic

        searchTask = Task {
            var vector: [Float]?
            var labelVectors: [[Float]]?
            var styleVectors: [[Float]]?
            if let embedder {
                if let text { vector = try? await embedder.embed(text: text) }
                // Each label is also checked by the embedding model, so Vision's misses don't drop images.
                var vs: [[Float]] = []
                for label in resolved.hardLabels {
                    guard let v = try? await embedder.embed(text: ResolvedQuery.labelPrompt(label)) else { break }
                    vs.append(v)
                }
                if vs.count == resolved.hardLabels.count { labelVectors = vs }
                // Style tags (golden hour, aerial …) are judged by the same model, against a fixed prompt.
                var ss: [[Float]] = []
                for style in filters.styles {
                    guard let v = try? await embedder.embed(text: style.prompt) else { break }
                    ss.append(v)
                }
                if ss.count == filters.styles.count { styleVectors = ss }
            }
            guard !Task.isCancelled else { return }
            let outcome = await index.search(resolved, vector: vector, labelVectors: labelVectors,
                                             styleVectors: styleVectors, scope: scope, calibration: calibration)
            guard !Task.isCancelled else { return }
            hits = outcome.hits
            total = outcome.total
            pruneSelection()
            searchMilliseconds = outcome.milliseconds
        }
    }
}

// MARK: - Selection and details

extension AppModel {
    enum ClickKind { case plain, toggle, extend }

    /// A click on a result. Plain selects only it; ⌘ toggles it; ⇧ selects the range from the anchor.
    func click(_ id: UUID, kind: ClickKind) {
        switch kind {
        case .plain:
            selectedIDs = [id]
            selectionAnchor = id
            focusedID = id
        case .toggle:
            if selectedIDs.contains(id) {
                selectedIDs.remove(id)
                if focusedID == id { focusedID = hits.last(where: { selectedIDs.contains($0.id) })?.id }
            } else {
                selectedIDs.insert(id)
                focusedID = id
            }
            selectionAnchor = id
        case .extend:
            guard let anchor = selectionAnchor, let a = hits.firstIndex(where: { $0.id == anchor }),
                  let b = hits.firstIndex(where: { $0.id == id }) else { return click(id, kind: .plain) }
            selectedIDs.formUnion(hits[min(a, b)...max(a, b)].map(\.id))
            focusedID = id
        }
    }

    /// Arrow keys: move the focus by `offset` results, selecting only that one (⇧ extends).
    func moveFocus(by offset: Int, extend: Bool) {
        guard !hits.isEmpty else { return }
        let current = focusedID.flatMap { id in hits.firstIndex { $0.id == id } }
        let next = current.map { min(max($0 + offset, 0), hits.count - 1) } ?? 0
        let id = hits[next].id
        if extend {
            if selectionAnchor == nil { selectionAnchor = focusedID ?? id }
            click(id, kind: .extend)
        } else {
            click(id, kind: .plain)
        }
    }

    func selectAll() {
        selectedIDs = Set(hits.map(\.id))
        if focusedID == nil { focusedID = hits.first?.id }
        selectionAnchor = focusedID
    }

    func clearSelection() {
        selectedIDs = []
        focusedID = nil
        selectionAnchor = nil
    }

    /// Selected images in result order.
    var selectedHits: [SearchIndex.Hit] { hits.filter { selectedIDs.contains($0.id) } }

    /// After a search, drop selected images that are no longer in the results.
    func pruneSelection() {
        guard !selectedIDs.isEmpty else { return }
        let visible = Set(hits.map(\.id))
        selectedIDs.formIntersection(visible)
        if let f = focusedID, !visible.contains(f) { focusedID = hits.first { selectedIDs.contains($0.id) }?.id }
        if let a = selectionAnchor, !visible.contains(a) { selectionAnchor = focusedID }
    }

    func toggleInspector() { inspectorVisible.toggle() }

    /// Show the details of one image (context menu).
    func showDetails(_ id: UUID) {
        if !selectedIDs.contains(id) { click(id, kind: .plain) } else { focusedID = id }
        inspectorVisible = true
    }

    /// Everything the details panel shows about one image.
    struct ImageInfo: Sendable {
        var features: ImageFeatures
        var details: LibraryStore.Details?
        var url: URL?
        var folderName: String?
        var styles: [StyleTag]
    }

    func imageInfo(_ id: UUID) async -> ImageInfo? {
        guard let index, let features = await index.features(for: id) else { return nil }
        let details = try? await store.details([id])[id]
        let url = details.flatMap { access.fileURL(folderID: $0.folderID, relativePath: $0.relativePath) }
        let folderName = folders.first { $0.id == features.folderID }?.info.displayName
        var styles: [StyleTag] = []
        if let embedder {
            if stylePromptVectors == nil {
                var vs: [(StyleTag, [Float])] = []
                for tag in StyleTag.allCases {
                    if let v = try? await embedder.embed(text: tag.prompt) { vs.append((tag, v)) }
                }
                stylePromptVectors = vs
            }
            styles = await index.styleTags(for: id, prompts: stylePromptVectors ?? [], calibration: embedder.calibration)
        }
        return ImageInfo(features: features, details: details, url: url, folderName: folderName, styles: styles)
    }

    func reveal(_ ids: [UUID]) {
        Task {
            var urls: [URL] = []
            for id in ids {
                if let d = try? await store.details([id])[id],
                   let url = access.fileURL(folderID: d.folderID, relativePath: d.relativePath) { urls.append(url) }
            }
            if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        }
    }

    /// File URLs of the given images (for copy and drag).
    func fileURLs(_ ids: [UUID]) async -> [URL] {
        guard let all = try? await store.details(ids) else { return [] }
        return ids.compactMap { id in
            all[id].flatMap { access.fileURL(folderID: $0.folderID, relativePath: $0.relativePath) }
        }
    }

    /// Edit › Copy with images selected: puts the files on the pasteboard, as Finder does.
    func copySelection() {
        let ids = selectedHits.map(\.id)
        guard !ids.isEmpty else { return }
        Task {
            let urls = await fileURLs(ids)
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects(urls as [NSURL])
        }
    }
}

// MARK: - Export

extension AppModel {
    enum ExportKind { case folder, zip }

    /// The images an export acts on: the selection, in result order.
    var exportTargets: [UUID] { selectedHits.map(\.id) }

    var canExport: Bool { !selectedIDs.isEmpty && exportProgress == nil }

    /// Asks where to put the selected originals, then copies them there (or into a zip).
    func export(_ kind: ExportKind, ids: [UUID]? = nil) {
        let ids = ids ?? exportTargets
        guard !ids.isEmpty, exportProgress == nil else { return }
        let count = ids.count
        let destination: URL
        switch kind {
        case .folder:
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = String(localized: "Export")
            panel.message = String(localized: "Choose a folder for \(count) images. The originals are copied; nothing is moved.")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destination = url
        case .zip:
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.zip]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = "\(suggestedExportName).zip"
            panel.prompt = String(localized: "Export")
            panel.message = String(localized: "\(count) images are copied into one zip; nothing is moved.")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destination = url
        }

        exportProgress = (0, count)
        Task {
            let sources = await fileURLs(ids)
            let total = sources.count
            exportProgress = (0, total)
            let report: @Sendable (Int) -> Void = { [weak self] done in
                Task { @MainActor in if self?.exportProgress != nil { self?.exportProgress = (done, total) } }
            }
            let result: Result<Exporter.Outcome, Error> = await Task.detached(priority: .userInitiated) {
                let scoped = destination.startAccessingSecurityScopedResource()
                defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
                switch kind {
                case .folder: return .success(Exporter.copy(sources, into: destination, progress: report))
                case .zip: return Result { try Exporter.zip(sources, to: destination, progress: report) }
                }
            }.value
            exportProgress = nil
            switch result {
            case .success(let outcome):
                if !outcome.written.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(outcome.written) }
                let missing = count - total + outcome.failed.count
                if missing > 0 {
                    let names = outcome.failed.prefix(5).joined(separator: ", ")
                    let list = "\(names)\(outcome.failed.count > 5 ? " …" : "")"
                    message = names.isEmpty
                        ? String(localized: "\(missing) of \(count) images couldn't be copied (their folder isn't available).")
                        : String(localized: "\(missing) of \(count) images couldn't be copied: \(list).")
                }
            case .failure(let error):
                message = String(localized: "Couldn't make the zip: \(error.localizedDescription)")
            }
        }
    }

    /// "Teinte – mostly blue, with people", or "Teinte export".
    var suggestedExportName: String {
        let name = suggestedLookName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return name.isEmpty ? String(localized: "Teinte export") : "Teinte – \(name.prefix(60))"
    }
}

