import Foundation
import SwiftData
import Testing
import TeinteCore
@testable import Teinte

@Suite("Folder watching", .serialized)
struct WatchingTests {
    static func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("teinte-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Collects events from the watcher's queue.
    final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [FolderWatcher.Change] = []
        func add(_ c: FolderWatcher.Change) { lock.withLock { items.append(c) } }
        var all: [FolderWatcher.Change] { lock.withLock { items } }
        func reset() { lock.withLock { items.removeAll() } }

        func wait(seconds: Double = 5, until done: ([FolderWatcher.Change]) -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if done(all) { return true }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return done(all)
        }
    }

    @Test func reportsNewFilesButNotHiddenOnes() async throws {
        let dir = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID(), events = Events()
        let watcher = FolderWatcher { got, change in if got == id { events.add(change) } }
        watcher.watch(id, url: dir)
        defer { watcher.unwatch(id) }
        try await Task.sleep(for: .milliseconds(300))

        try Data("x".utf8).write(to: dir.appendingPathComponent(".DS_Store"))
        #expect(await events.wait(seconds: 2.5) { !$0.isEmpty } == false, "hidden files don't trigger a rescan")

        try Data([1, 2, 3]).write(to: dir.appendingPathComponent("a.jpg"))
        #expect(await events.wait { $0.contains(.contents) })
    }

    @Test func reportsTheFolderItselfMoving() async throws {
        let parent = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: parent) }
        let dir = parent.appendingPathComponent("shoot", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = UUID(), events = Events()
        let watcher = FolderWatcher { got, change in if got == id { events.add(change) } }
        watcher.watch(id, url: dir)
        defer { watcher.unwatch(id) }
        try await Task.sleep(for: .milliseconds(300))

        try FileManager.default.moveItem(at: dir, to: parent.appendingPathComponent("shoot-renamed"))
        #expect(await events.wait { $0.contains(.root) })
    }

    @Test func scanOfAMissingFolderIsNilNotEmpty() throws {
        let dir = try Self.tempFolder()
        try FileManager.default.removeItem(at: dir)
        #expect(FolderScanner.scan(dir) == nil)
    }

    /// Scan → reconcile against a real store: a rename keeps the record (and so its analysis).
    @Test func renameKeepsTheRecordInTheStore() async throws {
        let dir = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 100).write(to: dir.appendingPathComponent("a.png"))
        try Data(repeating: 8, count: 200).write(to: dir.appendingPathComponent("b.png"))

        let container = try ModelContainer(
            for: WatchedFolder.self, ImageRecord.self, SavedLook.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = LibraryStore(modelContainer: container)
        let folder = try await store.addFolder(displayName: "test", bookmark: Data(), path: dir.path)

        let first = try await store.reconcile(folderID: folder.id, files: try #require(FolderScanner.scan(dir)))
        #expect(first.added == 2)
        let idA = try #require(try await store.pending(limit: 10).first { $0.relativePath == "a.png" }?.id)

        try FileManager.default.moveItem(at: dir.appendingPathComponent("a.png"),
                                         to: dir.appendingPathComponent("sub/a-final.png"))
        try FileManager.default.removeItem(at: dir.appendingPathComponent("b.png"))
        try Data(repeating: 9, count: 300).write(to: dir.appendingPathComponent("c.png"))

        let second = try await store.reconcile(folderID: folder.id, files: try #require(FolderScanner.scan(dir)))
        #expect(second.renamed.map(\.0) == [idA])
        #expect(second.renamed.first?.1 == "a-final.png")
        #expect(second.added == 1)
        #expect(second.removed.count == 1)
        let details = try await store.details([idA])[idA]
        #expect(details?.relativePath == "sub/a-final.png")

        let third = try await store.reconcile(folderID: folder.id, files: try #require(FolderScanner.scan(dir)))
        #expect(third.isEmpty)
    }
}
