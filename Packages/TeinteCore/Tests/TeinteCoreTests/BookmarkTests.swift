import Foundation
import Testing
@testable import TeinteCore

@Suite("Bookmark restore")
struct BookmarkTests {
    func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("teinte-bookmark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: url.appendingPathComponent("a.txt"))
        return url
    }

    /// Persist → drop all in-memory state → resolve → read a file.
    @Test(arguments: [false, true])
    func restoreAfterRestart(securityScoped: Bool) throws {
        let folder = try makeFolder()
        let persisted: Data = try FolderBookmark.create(for: folder, securityScoped: securityScoped)

        guard case .ok(let url, _) = FolderBookmark.resolve(persisted, securityScoped: securityScoped) else {
            Issue.record("bookmark didn't resolve"); return
        }
        let started = securityScoped && url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        #expect(url.standardizedFileURL.resolvingSymlinksInPath() == folder.standardizedFileURL.resolvingSymlinksInPath())
        #expect(try String(contentsOf: url.appendingPathComponent("a.txt"), encoding: .utf8) == "hello")
    }

    @Test func followsMovedFolder() throws {
        let folder = try makeFolder()
        let data = try FolderBookmark.create(for: folder, securityScoped: false)
        let moved = folder.deletingLastPathComponent().appendingPathComponent("moved-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: folder, to: moved)

        guard case .ok(let url, _) = FolderBookmark.resolve(data, securityScoped: false) else {
            Issue.record("moved folder didn't resolve"); return
        }
        #expect(url.lastPathComponent == moved.lastPathComponent)
    }

    @Test func missingFolderIsUnavailable() throws {
        let folder = try makeFolder()
        let data = try FolderBookmark.create(for: folder, securityScoped: false)
        try FileManager.default.removeItem(at: folder)
        guard case .unavailable = FolderBookmark.resolve(data, securityScoped: false) else {
            Issue.record("expected unavailable"); return
        }
    }

    @Test func overlap() {
        let root = URL(fileURLWithPath: "/tmp/photos")
        let child = URL(fileURLWithPath: "/tmp/photos/2026")
        let other = URL(fileURLWithPath: "/tmp/other")
        #expect(FolderBookmark.overlap(of: child, with: [root]) == .insideExisting(root))
        #expect(FolderBookmark.overlap(of: root, with: [child, other]) == .containsExisting([child]))
        #expect(FolderBookmark.overlap(of: root, with: [root]) == .same(root))
        #expect(FolderBookmark.overlap(of: other, with: [root]) == FolderBookmark.Overlap.none)
    }
}
