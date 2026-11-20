import Foundation
import TeinteCore
import UniformTypeIdentifiers

/// Holds security-scoped access to every library folder for the app's lifetime,
/// and maps image records to file URLs.
final class FolderAccess: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [UUID: URL] = [:]

    /// Resolve a folder bookmark and start access. Returns nil if the folder is unavailable.
    /// `refreshed` is called with a new bookmark when the old one was stale.
    func open(_ folder: FolderInfo, refreshed: (Data, URL) -> Void) -> URL? {
        switch FolderBookmark.resolve(folder.bookmark) {
        case .ok(let url, let newBookmark):
            // A folder moved to the Trash still resolves; treat it as gone.
            if url.pathComponents.contains(".Trash") { return nil }
            _ = url.startAccessingSecurityScopedResource()
            lock.withLock { urls[folder.id] = url }
            if let newBookmark { refreshed(newBookmark, url) }
            return url
        case .unavailable:
            return nil
        }
    }

    /// Register a folder the user just picked (access is already granted by the open panel / drop).
    func register(_ id: UUID, url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        lock.withLock { urls[id] = url }
    }

    func close(_ id: UUID) {
        lock.withLock {
            urls.removeValue(forKey: id)?.stopAccessingSecurityScopedResource()
        }
    }

    func folderURL(_ id: UUID) -> URL? { lock.withLock { urls[id] } }

    func isAvailable(_ id: UUID) -> Bool { folderURL(id) != nil }

    func fileURL(folderID: UUID, relativePath: String) -> URL? {
        folderURL(folderID)?.appendingPathComponent(relativePath, isDirectory: false)
    }

    var openFolderURLs: [URL] { lock.withLock { Array(urls.values) } }
}

/// Recursive scan of a folder for images ImageIO can read.
enum FolderScanner {
    /// Nil when the folder itself is unreachable (unmounted, moved, deleted). Callers must not
    /// read that as "every image is gone".
    static func scan(_ root: URL) -> [ScannedFile]? {
        guard isReachable(root) else { return nil }
        let keys: [URLResourceKey] = [.contentTypeKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        var out: [ScannedFile] = []
        for case let url as URL in e {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                  let type = v.contentType, type.conforms(to: .image), !type.conforms(to: .svg) else { continue }
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard path.hasPrefix(rootPath) else { continue }
            let relative = String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            out.append(ScannedFile(
                relativePath: relative, size: Int64(v.fileSize ?? 0),
                modified: v.contentModificationDate ?? .distantPast, created: v.creationDate ?? .distantPast))
        }
        // The folder may have gone while we walked it; an empty or partial walk must not delete records.
        return isReachable(root) ? out : nil
    }

    static func isReachable(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
