import Foundation
import SwiftData
import TeinteCore

/// A file found on disk during a scan.
typealias ScannedFile = Reconcile.OnDisk

/// Work item for the analysis queue.
struct PendingImage: Sendable {
    var id: UUID
    var folderID: UUID
    var relativePath: String
}

/// What analysis produced for one image.
struct AnalysisResult: Sendable {
    var id: UUID
    var pixelWidth: Int
    var pixelHeight: Int
    var colours: ColourProfile
    var personCount: Int
    var faceCount: Int
    var hasText: Bool
    var labels: [(String, Float)]
    var embedding: [Float]?
    var recognizedText: String = ""
    var aesthetics: Float?
    var isUtility: Bool = false
}

struct FolderInfo: Sendable, Identifiable, Hashable {
    var id: UUID
    var displayName: String
    var bookmark: Data
    var path: String
}

/// All SwiftData access, off the main actor.
@ModelActor
actor LibraryStore {
    // MARK: Folders

    func folders() throws -> [FolderInfo] {
        try modelContext.fetch(FetchDescriptor<WatchedFolder>(sortBy: [SortDescriptor(\.addedAt)]))
            .map { FolderInfo(id: $0.id, displayName: $0.displayName, bookmark: $0.bookmark, path: $0.lastResolvedPath) }
    }

    func addFolder(displayName: String, bookmark: Data, path: String) throws -> FolderInfo {
        let folder = WatchedFolder(displayName: displayName, bookmark: bookmark, path: path)
        modelContext.insert(folder)
        try modelContext.save()
        return FolderInfo(id: folder.id, displayName: displayName, bookmark: bookmark, path: path)
    }

    func updateBookmark(folderID: UUID, bookmark: Data, path: String) throws {
        guard let folder = try folder(folderID) else { return }
        folder.bookmark = bookmark
        folder.lastResolvedPath = path
        try modelContext.save()
    }

    func removeFolder(_ folderID: UUID) throws -> [UUID] {
        guard let folder = try folder(folderID) else { return [] }
        let ids = folder.images.map(\.id)
        modelContext.delete(folder)
        try modelContext.save()
        return ids
    }

    private func folder(_ id: UUID) throws -> WatchedFolder? {
        var d = FetchDescriptor<WatchedFolder>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try modelContext.fetch(d).first
    }

    // MARK: Reconcile

    struct ReconcileOutcome: Sendable {
        var added = 0, changed = 0
        var removed: [UUID] = []
        /// Records that kept their analysis under a new path: id → new file name.
        var renamed: [(UUID, String)] = []

        var isEmpty: Bool { added == 0 && changed == 0 && removed.isEmpty && renamed.isEmpty }
    }

    /// Bring the index in line with what's on disk: new → pending, changed → pending again,
    /// renamed or moved inside the folder → same record under the new path, gone → deleted.
    func reconcile(folderID: UUID, files: [ScannedFile]) throws -> ReconcileOutcome {
        guard let folder = try folder(folderID) else { return ReconcileOutcome() }
        var byID: [UUID: ImageRecord] = [:]
        for r in folder.images { byID[r.id] = r }
        let plan = Reconcile.plan(
            known: byID.values.map { .init(id: $0.id, relativePath: $0.relativePath, size: $0.fileSize, modified: $0.contentModified) },
            onDisk: files)
        guard !plan.isEmpty else { return ReconcileOutcome() }

        var outcome = ReconcileOutcome()
        for (id, f) in plan.changed {
            guard let r = byID[id] else { continue }
            r.fileSize = f.size
            r.contentModified = f.modified
            r.status = .pending
            r.failureReason = nil
            outcome.changed += 1
        }
        for (id, f) in plan.renamed {
            guard let r = byID[id] else { continue }
            r.relativePath = f.relativePath
            r.fileName = (f.relativePath as NSString).lastPathComponent
            r.contentModified = f.modified
            outcome.renamed.append((id, r.fileName))
        }
        for f in plan.added {
            modelContext.insert(ImageRecord(
                folder: folder, relativePath: f.relativePath, fileSize: f.size,
                contentModified: f.modified, created: f.created))
            outcome.added += 1
        }
        for id in plan.removed {
            guard let r = byID[id] else { continue }
            modelContext.delete(r)
            outcome.removed.append(id)
        }
        try modelContext.save()
        return outcome
    }

    // MARK: Analysis queue

    func pending(limit: Int) throws -> [PendingImage] {
        let pending = AnalysisStatus.pending.rawValue
        let done = AnalysisStatus.done.rawValue
        let version = currentAnalysisVersion
        var d = FetchDescriptor<ImageRecord>(
            predicate: #Predicate { $0.statusRaw == pending || ($0.statusRaw == done && $0.analysisVersion < version) },
            sortBy: [SortDescriptor(\.addedAt), SortDescriptor(\.relativePath)])
        d.fetchLimit = limit
        return try modelContext.fetch(d).map { PendingImage(id: $0.id, folderID: $0.folderID, relativePath: $0.relativePath) }
    }

    func counts() throws -> (done: Int, total: Int) {
        let total = try modelContext.fetchCount(FetchDescriptor<ImageRecord>())
        let pending = AnalysisStatus.pending.rawValue
        let remaining = try modelContext.fetchCount(FetchDescriptor<ImageRecord>(predicate: #Predicate { $0.statusRaw == pending }))
        return (total - remaining, total)
    }

    func save(_ results: [AnalysisResult], failures: [(UUID, String)]) throws -> [ImageFeatures] {
        let ids = results.map(\.id) + failures.map(\.0)
        let records = try modelContext.fetch(FetchDescriptor<ImageRecord>(predicate: #Predicate { ids.contains($0.id) }))
        var byID: [UUID: ImageRecord] = [:]
        for r in records { byID[r.id] = r }

        var features: [ImageFeatures] = []
        for result in results {
            guard let r = byID[result.id] else { continue }
            r.pixelWidth = result.pixelWidth
            r.pixelHeight = result.pixelHeight
            r.bucketShares = result.colours.bucketShares
            r.palette = result.colours.palette.flatMap { [$0.colour.l, $0.colour.a, $0.colour.b, $0.share] }
            r.personCount = result.personCount
            r.faceCount = result.faceCount
            r.hasText = result.hasText
            r.labels = result.labels.map(\.0)
            r.labelConfidences = result.labels.map(\.1)
            r.subjectShares = result.colours.subjectShares
            r.backgroundShares = result.colours.backgroundShares
            r.look = result.colours.look
            r.recognizedText = result.recognizedText
            r.aesthetics = result.aesthetics
            r.isUtility = result.isUtility
            r.status = .done
            r.failureReason = nil
            r.analysisVersion = currentAnalysisVersion
            features.append(r.features(embedding: result.embedding.map(l2Normalized), available: true))
        }
        for (id, reason) in failures {
            guard let r = byID[id] else { continue }
            r.status = .failed
            r.failureReason = reason
            r.analysisVersion = currentAnalysisVersion
        }
        try modelContext.save()
        return features
    }

    /// Analysed records, for building the in-memory index at launch.
    func analysedFeatures() throws -> [ImageFeatures] {
        let done = AnalysisStatus.done.rawValue
        return try modelContext.fetch(FetchDescriptor<ImageRecord>(predicate: #Predicate { $0.statusRaw == done }))
            .map { $0.features(embedding: nil, available: true) }
    }

    /// Debug details for one image (Phase 1 overlay and list).
    struct Details: Sendable {
        var relativePath: String
        var folderID: UUID
        var palette: [PaletteEntry]
        var labels: [(String, Float)]
        var failureReason: String?
        var recognizedText: String
        var fileSize: Int64 = 0
        var created: Date = .distantPast
        var contentModified: Date = .distantPast
    }

    func details(_ ids: [UUID]) throws -> [UUID: Details] {
        let records = try modelContext.fetch(FetchDescriptor<ImageRecord>(predicate: #Predicate { ids.contains($0.id) }))
        var out: [UUID: Details] = [:]
        for r in records {
            out[r.id] = Details(
                relativePath: r.relativePath, folderID: r.folderID, palette: r.paletteEntries,
                labels: Array(zip(r.labels, r.labelConfidences)), failureReason: r.failureReason,
                recognizedText: r.recognizedText, fileSize: r.fileSize, created: r.created,
                contentModified: r.contentModified)
        }
        return out
    }

    /// Where each image lives: folder and path inside it (for drag-out and Quick Look).
    func locations(_ ids: [UUID]) throws -> [UUID: (folderID: UUID, relativePath: String)] {
        var descriptor = FetchDescriptor<ImageRecord>(predicate: #Predicate { ids.contains($0.id) })
        descriptor.propertiesToFetch = [\.id, \.folderID, \.relativePath]
        var out: [UUID: (folderID: UUID, relativePath: String)] = [:]
        for r in try modelContext.fetch(descriptor) { out[r.id] = (r.folderID, r.relativePath) }
        return out
    }

    /// Send analysed images back to the queue (e.g. their embeddings belong to an older model).
    func markPending(_ ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        let records = try modelContext.fetch(FetchDescriptor<ImageRecord>(predicate: #Predicate { ids.contains($0.id) }))
        for r in records { r.status = .pending }
        try modelContext.save()
    }

    func imageCount(folderID: UUID) throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<ImageRecord>(predicate: #Predicate { $0.folderID == folderID }))
    }

    /// Every Vision label seen in the library.
    func labelVocabulary() throws -> Set<String> {
        let done = AnalysisStatus.done.rawValue
        var d = FetchDescriptor<ImageRecord>(predicate: #Predicate { $0.statusRaw == done })
        d.propertiesToFetch = [\.labels]
        return Set(try modelContext.fetch(d).flatMap(\.labels))
    }

    // MARK: Saved looks

    func looks() throws -> [LookInfo] {
        try modelContext.fetch(FetchDescriptor<SavedLook>(sortBy: [SortDescriptor(\.sortIndex), SortDescriptor(\.createdAt)]))
            .map(LookInfo.init)
    }

    func addLook(name: String, query: String, filters: QueryFilters, chipsEdited: Bool) throws -> LookInfo {
        let next = (try modelContext.fetch(FetchDescriptor<SavedLook>()).map(\.sortIndex).max() ?? -1) + 1
        let look = SavedLook(name: name, query: query, filtersJSON: try JSONEncoder().encode(filters),
                             chipsEdited: chipsEdited, sortIndex: next)
        modelContext.insert(look)
        try modelContext.save()
        return LookInfo(look)
    }

    func renameLook(_ id: UUID, to name: String) throws {
        guard let look = try look(id) else { return }
        look.name = name
        try modelContext.save()
    }

    func deleteLook(_ id: UUID) throws {
        guard let look = try look(id) else { return }
        modelContext.delete(look)
        try modelContext.save()
    }

    /// Persist a new order (IDs in display order).
    func reorderLooks(_ ids: [UUID]) throws {
        let all = try modelContext.fetch(FetchDescriptor<SavedLook>())
        for look in all { look.sortIndex = ids.firstIndex(of: look.id) ?? ids.count }
        try modelContext.save()
    }

    private func look(_ id: UUID) throws -> SavedLook? {
        try modelContext.fetch(FetchDescriptor<SavedLook>(predicate: #Predicate { $0.id == id })).first
    }
}

struct LookInfo: Sendable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var query: String
    var filters: QueryFilters
    var chipsEdited: Bool

    init(_ look: SavedLook) {
        id = look.id
        name = look.name
        query = look.query
        filters = (try? JSONDecoder().decode(QueryFilters.self, from: look.filtersJSON)) ?? .empty
        chipsEdited = look.chipsEdited
    }
}
