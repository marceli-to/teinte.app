import Foundation

/// File names for a flat export: clashes get "-2", "-3" … before the extension.
public enum ExportNaming {
    /// - Parameters:
    ///   - names: the source file names, in export order.
    ///   - existing: names already in the destination. Compared case-insensitively, as APFS does by default.
    /// - Returns: one unique name per input, same order.
    public static func uniqueNames(for names: [String], existing: Set<String> = []) -> [String] {
        var taken = Set(existing.map { $0.lowercased() })
        return names.map { name in
            let ext = (name as NSString).pathExtension
            let stem = (name as NSString).deletingPathExtension
            var candidate = name
            var n = 2
            while taken.contains(candidate.lowercased()) {
                candidate = ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"
                n += 1
            }
            taken.insert(candidate.lowercased())
            return candidate
        }
    }
}
