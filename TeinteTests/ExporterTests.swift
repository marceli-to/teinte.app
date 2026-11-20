import Foundation
import Testing
@testable import Teinte

@Suite("Export")
struct ExporterTests {
    /// Two folders with a clashing "a.jpg", plus "b.jpg".
    static func sources() throws -> (root: URL, files: [URL]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("exporter-\(UUID().uuidString)")
        var files: [URL] = []
        for (dir, name, body) in [("one", "a.jpg", "A1"), ("two", "a.jpg", "A2"), ("two", "b.jpg", "B")] {
            let folder = root.appendingPathComponent(dir)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(name)
            try Data(body.utf8).write(to: url)
            files.append(url)
        }
        return (root, files)
    }

    @Test func copiesFlatWithSuffixesAndLeavesOriginals() throws {
        let (root, files) = try Self.sources()
        defer { try? FileManager.default.removeItem(at: root) }
        let out = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: out.appendingPathComponent("b.jpg"))

        let outcome = Exporter.copy(files, into: out) { _ in }
        #expect(outcome.copied == 3)
        #expect(outcome.failed.isEmpty)
        #expect(outcome.written.map(\.lastPathComponent) == ["a.jpg", "a-2.jpg", "b-2.jpg"])
        #expect(try String(contentsOf: out.appendingPathComponent("a-2.jpg"), encoding: .utf8) == "A2")
        #expect(try String(contentsOf: out.appendingPathComponent("b.jpg"), encoding: .utf8) == "old")
        #expect(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test func missingSourceIsReported() throws {
        let (root, files) = try Self.sources()
        defer { try? FileManager.default.removeItem(at: root) }
        let out = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let outcome = Exporter.copy(files + [root.appendingPathComponent("gone.jpg")], into: out) { _ in }
        #expect(outcome.copied == 3)
        #expect(outcome.failed == ["gone.jpg"])
    }

    @Test func zipContainsAllFiles() throws {
        let (root, files) = try Self.sources()
        defer { try? FileManager.default.removeItem(at: root) }
        let zipURL = root.appendingPathComponent("Export.zip")
        try Data("stale".utf8).write(to: zipURL) // replaced, as after the save panel's "Replace"

        let outcome = try Exporter.zip(files, to: zipURL) { _ in }
        #expect(outcome.written == [zipURL])
        #expect(outcome.copied == 3)

        let list = Process()
        list.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        list.arguments = ["-1", zipURL.path]
        let pipe = Pipe()
        list.standardOutput = pipe
        try list.run()
        list.waitUntilExit()
        let entries = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").map(String.init).filter { !$0.hasSuffix("/") }.sorted()
        #expect(entries == ["Export/a-2.jpg", "Export/a.jpg", "Export/b.jpg"])
    }
}
