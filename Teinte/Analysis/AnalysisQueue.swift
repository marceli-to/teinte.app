import CoreGraphics
import Foundation
import ImageIO
import TeinteCore

struct AnalysisProgress: Sendable, Equatable {
    var done: Int
    var total: Int
    var imagesPerSecond: Double
    var isRunning: Bool

    var remainingSeconds: Double? {
        guard imagesPerSecond > 0, total > done else { return nil }
        return Double(total - done) / imagesPerSecond
    }

    static let idle = AnalysisProgress(done: 0, total: 0, imagesPerSecond: 0, isRunning: false)
}

/// Bounded, cancellable, resumable analysis. State lives in SwiftData (`status`), so quitting mid-way is safe.
actor AnalysisQueue {
    private let store: LibraryStore
    private let access: FolderAccess
    private let index: SearchIndex
    private let embedder: EmbeddingModel?
    private let thumbnails: ThumbnailCache
    private let onProgress: @Sendable (AnalysisProgress) -> Void
    private let onBatch: @Sendable () -> Void

    private var task: Task<Void, Never>?
    private let concurrency = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)

    init(store: LibraryStore, access: FolderAccess, index: SearchIndex, embedder: EmbeddingModel?,
         thumbnails: ThumbnailCache,
         onProgress: @escaping @Sendable (AnalysisProgress) -> Void,
         onBatch: @escaping @Sendable () -> Void) {
        self.store = store; self.access = access; self.index = index; self.embedder = embedder
        self.thumbnails = thumbnails; self.onProgress = onProgress; self.onBatch = onBatch
    }

    /// Start (or keep running). Safe to call repeatedly.
    func start() {
        guard task == nil else { return }
        task = Task(priority: .utility) { [weak self] in
            await self?.run()
            await self?.finished()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func finished() { task = nil }

    private func run() async {
        let started = Date()
        var processed = 0
        var skipped = Set<UUID>()

        while !Task.isCancelled {
            guard var batch = try? await store.pending(limit: 64 + skipped.count) else { break }
            batch.removeAll { skipped.contains($0.id) }
            if batch.isEmpty { break }

            var results: [AnalysisResult] = []
            var failures: [(UUID, String)] = []

            await withTaskGroup(of: (UUID, Result<AnalysisResult, AnalysisError>).self) { group in
                var iterator = batch.makeIterator()
                func addNext() -> Bool {
                    guard let item = iterator.next() else { return false }
                    group.addTask(priority: .utility) { [access, embedder, thumbnails] in
                        (item.id, await Self.analyze(item, access: access, embedder: embedder, thumbnails: thumbnails))
                    }
                    return true
                }
                for _ in 0..<concurrency where addNext() {}
                for await (id, result) in group {
                    switch result {
                    case .success(let r): results.append(r)
                    case .failure(.folderUnavailable): skipped.insert(id)
                    case .failure(let e): failures.append((id, e.description))
                    }
                    if !Task.isCancelled { _ = addNext() }
                }
            }
            if Task.isCancelled && results.isEmpty { break }

            if let features = try? await store.save(results, failures: failures) {
                await index.upsert(features)
            }
            processed += results.count + failures.count
            onBatch()
            if let counts = try? await store.counts() {
                let rate = Double(processed) / max(Date().timeIntervalSince(started), 0.001)
                onProgress(AnalysisProgress(done: counts.done, total: counts.total, imagesPerSecond: rate, isRunning: true))
            }
        }
        if let counts = try? await store.counts() {
            onProgress(AnalysisProgress(done: counts.done, total: counts.total, imagesPerSecond: 0, isRunning: false))
        }
    }

    enum AnalysisError: Error, CustomStringConvertible {
        case folderUnavailable, unreadable, vision(String)
        var description: String {
            switch self {
            case .folderUnavailable: "folder unavailable"
            case .unreadable: "couldn't decode the image"
            case .vision(let s): "Vision: \(s)"
            }
        }
    }

    private static func analyze(_ item: PendingImage, access: FolderAccess, embedder: EmbeddingModel?,
                                thumbnails: ThumbnailCache) async -> Result<AnalysisResult, AnalysisError> {
        guard let url = access.fileURL(folderID: item.folderID, relativePath: item.relativePath) else {
            return .failure(.folderUnavailable)
        }
        guard let loaded = ImageLoader.load(url) else { return .failure(.unreadable) }
        thumbnails.store(loaded.thumbnail, for: item.id)

        let vision: VisionAnalyzer.Output
        do {
            vision = try await VisionAnalyzer.analyze(thumbnail: loaded.thumbnail, detail: loaded.detail)
        } catch {
            return .failure(.vision(error.localizedDescription))
        }
        // After Vision: the saliency map weights the subject's colours over the background.
        let colours = ColourAnalyzer().analyze(loaded.thumbnail, saliency: vision.saliency)
        let embedding = try? await embedder?.embed(image: loaded.thumbnail)

        return .success(AnalysisResult(
            id: item.id, pixelWidth: loaded.pixelWidth, pixelHeight: loaded.pixelHeight, colours: colours,
            personCount: vision.personCount, faceCount: vision.faceCount, hasText: vision.hasText,
            labels: vision.labels, embedding: embedding, recognizedText: vision.recognizedText,
            aesthetics: vision.aesthetics, isUtility: vision.isUtility))
    }
}

/// Thumbnails on disk (Caches) plus a small in-memory cache for the grid.
final class ThumbnailCache: @unchecked Sendable {
    let directory: URL
    private let memory = NSCache<NSUUID, CGImageBox>()

    final class CGImageBox { let image: CGImage; init(_ i: CGImage) { image = i } }

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        memory.countLimit = 600
    }

    func url(for id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).heic") }

    func store(_ image: CGImage, for id: UUID) {
        ImageLoader.writeThumbnail(image, to: url(for: id))
    }

    func image(for id: UUID) -> CGImage? {
        if let box = memory.object(forKey: id as NSUUID) { return box.image }
        guard let src = CGImageSourceCreateWithURL(url(for: id) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        memory.setObject(CGImageBox(img), forKey: id as NSUUID)
        return img
    }

    func remove(_ id: UUID) {
        memory.removeObject(forKey: id as NSUUID)
        try? FileManager.default.removeItem(at: url(for: id))
    }
}
