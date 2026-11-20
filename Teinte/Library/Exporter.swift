import Foundation
import TeinteCore

/// Copies originals out of the library: into one flat folder, or into a zip. Never moves or changes them.
enum Exporter {
    struct Outcome: Sendable {
        /// What was written: the copied files, or the zip.
        var written: [URL]
        var copied: Int
        var failed: [String]
    }

    /// Copies `sources` into `folder`. Names that clash (with each other or with files already there) get "-2", "-3" ….
    static func copy(_ sources: [URL], into folder: URL, progress: @Sendable (Int) -> Void) -> Outcome {
        let fm = FileManager.default
        let existing = Set((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])
        let names = ExportNaming.uniqueNames(for: sources.map(\.lastPathComponent), existing: existing)
        var written: [URL] = [], failed: [String] = []
        for (i, (source, name)) in Swift.zip(sources, names).enumerated() {
            let target = folder.appendingPathComponent(name)
            do {
                try fm.copyItem(at: source, to: target)
                written.append(target)
            } catch {
                failed.append(source.lastPathComponent)
            }
            progress(i + 1)
        }
        return Outcome(written: written, copied: written.count, failed: failed)
    }

    /// Copies `sources` into a folder named like the zip, zips it with `NSFileCoordinator` (`.forUploading`)
    /// and moves the zip to `zipURL`, replacing what's there (the save panel already asked).
    static func zip(_ sources: [URL], to zipURL: URL, progress: @Sendable (Int) -> Void) throws -> Outcome {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
        let folder = staging.appendingPathComponent(zipURL.deletingPathExtension().lastPathComponent, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        var outcome = copy(sources, into: folder, progress: progress)
        guard outcome.copied > 0 else { return outcome }

        var coordinatorError: NSError?
        var blockError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordinatorError) { zipped in
            do {
                // The zip only exists inside this block.
                let local = staging.appendingPathComponent("out.zip")
                try fm.copyItem(at: zipped, to: local)
                if fm.fileExists(atPath: zipURL.path) {
                    _ = try fm.replaceItemAt(zipURL, withItemAt: local)
                } else {
                    try fm.moveItem(at: local, to: zipURL)
                }
            } catch {
                blockError = error
            }
        }
        if let error = coordinatorError ?? blockError { throw error }
        outcome.written = [zipURL]
        return outcome
    }
}
