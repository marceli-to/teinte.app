import Foundation

/// Security-scoped, read-only folder bookmarks: create, resolve, refresh when stale.
public enum FolderBookmark {
    public enum Resolution: Sendable {
        /// Resolved. `refreshedBookmark` is set when the old one was stale and has been recreated; persist it.
        case ok(url: URL, refreshedBookmark: Data?)
        /// The folder can't be found (deleted, on an unmounted volume, …).
        case unavailable(Error)
    }

    /// `securityScoped` is true in the app (sandbox); tests can pass false.
    public static func create(for url: URL, securityScoped: Bool = true) throws -> Data {
        var options: URL.BookmarkCreationOptions = []
        if securityScoped { options.formUnion([.withSecurityScope, .securityScopeAllowOnlyReadAccess]) }
        return try url.bookmarkData(options: options, includingResourceValuesForKeys: [.nameKey], relativeTo: nil)
    }

    public static func resolve(_ data: Data, securityScoped: Bool = true) -> Resolution {
        var stale = false
        do {
            var options: URL.BookmarkResolutionOptions = [.withoutUI, .withoutMounting]
            if securityScoped { options.insert(.withSecurityScope) }
            let url = try URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                return .unavailable(CocoaError(.fileNoSuchFile))
            }
            var refreshed: Data?
            if stale {
                // Recreating needs access, which the caller may not have started yet.
                let started = securityScoped && url.startAccessingSecurityScopedResource()
                defer { if started { url.stopAccessingSecurityScopedResource() } }
                refreshed = try? create(for: url, securityScoped: securityScoped)
            }
            return .ok(url: url, refreshedBookmark: refreshed)
        } catch {
            return .unavailable(error)
        }
    }

    /// The relationship of a new folder to the folders already in the library.
    public enum Overlap: Equatable, Sendable {
        case none
        case same(URL)
        /// The new folder is inside an existing one: nothing to add.
        case insideExisting(URL)
        /// The new folder contains existing ones: they can be merged into it.
        case containsExisting([URL])
    }

    public static func overlap(of new: URL, with existing: [URL]) -> Overlap {
        let n = new.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        var contained: [URL] = []
        for url in existing {
            let e = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            if e == n { return .same(url) }
            if n.count > e.count, Array(n.prefix(e.count)) == e { return .insideExisting(url) }
            if e.count > n.count, Array(e.prefix(n.count)) == n { contained.append(url) }
        }
        return contained.isEmpty ? .none : .containsExisting(contained)
    }
}
