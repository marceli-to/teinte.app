import Foundation

/// Compares what the index knows about a folder with what's on disk.
///
/// - A path in both, with a different size or modification date → changed (analyse again).
/// - A path only on disk → added, unless it matches a vanished record by size and modification
///   date: then it's a rename or move inside the folder, and the record keeps its analysis.
/// - A path only in the index → removed.
public enum Reconcile {
    public struct Known: Sendable, Hashable {
        public var id: UUID
        public var relativePath: String
        public var size: Int64
        public var modified: Date

        public init(id: UUID, relativePath: String, size: Int64, modified: Date) {
            self.id = id; self.relativePath = relativePath; self.size = size; self.modified = modified
        }
    }

    public struct OnDisk: Sendable, Hashable {
        public var relativePath: String
        public var size: Int64
        public var modified: Date
        public var created: Date

        public init(relativePath: String, size: Int64, modified: Date, created: Date) {
            self.relativePath = relativePath; self.size = size; self.modified = modified; self.created = created
        }
    }

    public struct Plan: Sendable, Equatable {
        public var added: [OnDisk] = []
        /// Same path, new size or date.
        public var changed: [(id: UUID, file: OnDisk)] = []
        /// Same file under a new path.
        public var renamed: [(id: UUID, file: OnDisk)] = []
        public var removed: [UUID] = []

        public var isEmpty: Bool { added.isEmpty && changed.isEmpty && renamed.isEmpty && removed.isEmpty }

        public static func == (a: Plan, b: Plan) -> Bool {
            a.added == b.added && a.removed == b.removed
                && a.changed.map(\.id) == b.changed.map(\.id) && a.changed.map(\.file) == b.changed.map(\.file)
                && a.renamed.map(\.id) == b.renamed.map(\.id) && a.renamed.map(\.file) == b.renamed.map(\.file)
        }
    }

    /// Dates within this many seconds count as equal (FAT/exFAT and SMB round them).
    public static let dateTolerance: TimeInterval = 1

    public static func plan(known: [Known], onDisk: [OnDisk]) -> Plan {
        var plan = Plan()
        var byPath: [String: Known] = [:]
        for k in known { byPath[k.relativePath] = k }

        var fresh: [OnDisk] = []
        for f in onDisk {
            if let k = byPath.removeValue(forKey: f.relativePath) {
                if k.size != f.size || abs(k.modified.timeIntervalSince(f.modified)) > dateTolerance {
                    plan.changed.append((k.id, f))
                }
            } else {
                fresh.append(f)
            }
        }

        // Vanished records, grouped by size; a new file with the same size and date is the same file.
        var vanished: [Int64: [Known]] = [:]
        for k in byPath.values.sorted(by: { $0.relativePath < $1.relativePath }) { vanished[k.size, default: []].append(k) }
        for f in fresh {
            if var candidates = vanished[f.size],
               let i = candidates.firstIndex(where: { abs($0.modified.timeIntervalSince(f.modified)) <= dateTolerance }) {
                plan.renamed.append((candidates.remove(at: i).id, f))
                vanished[f.size] = candidates
            } else {
                plan.added.append(f)
            }
        }
        plan.removed = vanished.values.flatMap { $0 }.map(\.id).sorted { $0.uuidString < $1.uuidString }
        return plan
    }
}
