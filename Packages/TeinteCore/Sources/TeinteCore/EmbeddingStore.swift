import Foundation

/// Embeddings on disk, outside SwiftData: a fixed header, then fixed-size records.
///
/// Layout (little endian):
///   header (64 B): magic "TNTE", version u16, dimension u16, reserved u32, modelID (52 B, UTF-8, zero-padded)
///   record: UUID (16 B) + dimension × Float16
/// A record whose UUID is all zero is a tombstone. Writes are appends; `compact()` rewrites live records.
public final class EmbeddingStore: @unchecked Sendable {
    public let url: URL
    public let dimension: Int
    public let modelID: String

    private let lock = NSLock()
    private var offsets: [UUID: UInt64] = [:]
    private var deadCount = 0
    private var handle: FileHandle?

    static let magic: [UInt8] = Array("TNTE".utf8)
    static let version: UInt16 = 1
    static let headerSize = 64
    var recordSize: Int { 16 + dimension * 2 }

    public enum StoreError: Error { case badHeader, modelMismatch(found: String) }

    /// Opens or creates the store. If the file belongs to a different model or dimension it's reset
    /// (the caller then re-embeds; `wasReset` tells it to).
    public private(set) var wasReset = false

    public init(url: URL, dimension: Int, modelID: String) throws {
        self.url = url; self.dimension = dimension; self.modelID = modelID
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            do { try loadIndex() } catch { try reset(); wasReset = true }
        } else {
            try reset()
        }
        handle = try FileHandle(forUpdating: url)
    }

    deinit { try? handle?.close() }

    public var count: Int { lock.withLock { offsets.count } }

    public func contains(_ id: UUID) -> Bool { lock.withLock { offsets[id] != nil } }

    /// Append or replace one embedding. Replacing tombstones the old record.
    public func put(_ id: UUID, _ vector: [Float]) throws {
        try putMany([(id, vector)])
    }

    public func putMany(_ items: [(UUID, [Float])]) throws {
        guard !items.isEmpty else { return }
        try lock.withLock {
            guard let handle else { return }
            var data = Data(capacity: items.count * recordSize)
            for (id, _) in items where offsets[id] != nil {
                try tombstone(at: offsets[id]!, handle: handle)
                deadCount += 1
            }
            var end = try handle.seekToEnd()
            for (id, vector) in items {
                precondition(vector.count == dimension, "embedding dimension mismatch")
                data.append(contentsOf: Self.bytes(of: id))
                for v in vector { withUnsafeBytes(of: Float16(v).bitPattern.littleEndian) { data.append(contentsOf: $0) } }
                offsets[id] = end
                end += UInt64(recordSize)
            }
            try handle.write(contentsOf: data)
        }
    }

    public func remove(_ id: UUID) throws {
        try lock.withLock {
            guard let handle, let offset = offsets.removeValue(forKey: id) else { return }
            try tombstone(at: offset, handle: handle)
            deadCount += 1
        }
    }

    /// Read every live embedding. 10k × 768 takes a few ms.
    public func loadAll() throws -> [UUID: [Float]] {
        try lock.withLock {
            let data = try Data(contentsOf: url, options: .alwaysMapped)
            var out: [UUID: [Float]] = [:]
            out.reserveCapacity(offsets.count)
            data.withUnsafeBytes { raw in
                for (id, offset) in offsets {
                    let base = Int(offset) + 16
                    var v = [Float](repeating: 0, count: dimension)
                    for d in 0..<dimension {
                        let bits = raw.loadUnaligned(fromByteOffset: base + d * 2, as: UInt16.self)
                        v[d] = Float(Float16(bitPattern: UInt16(littleEndian: bits)))
                    }
                    out[id] = v
                }
            }
            return out
        }
    }

    /// Fraction of records that are tombstones.
    public var deadFraction: Double {
        lock.withLock {
            let total = offsets.count + deadCount
            return total == 0 ? 0 : Double(deadCount) / Double(total)
        }
    }

    /// Rewrite the file with live records only.
    public func compact() throws {
        let live = try loadAll()
        try lock.withLock {
            try handle?.close()
            handle = nil
            let tmp = url.appendingPathExtension("tmp")
            try Self.header(dimension: dimension, modelID: modelID).write(to: tmp)
            let h = try FileHandle(forUpdating: tmp)
            try h.seekToEnd()
            var newOffsets: [UUID: UInt64] = [:]
            var data = Data(capacity: live.count * recordSize)
            var end = UInt64(Self.headerSize)
            for (id, vector) in live.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                data.append(contentsOf: Self.bytes(of: id))
                for v in vector { withUnsafeBytes(of: Float16(v).bitPattern.littleEndian) { data.append(contentsOf: $0) } }
                newOffsets[id] = end
                end += UInt64(recordSize)
            }
            try h.write(contentsOf: data)
            try h.close()
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            offsets = newOffsets
            deadCount = 0
            handle = try FileHandle(forUpdating: url)
        }
    }

    // MARK: - Private

    private func reset() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.header(dimension: dimension, modelID: modelID).write(to: url, options: .atomic)
        offsets = [:]
        deadCount = 0
    }

    private func loadIndex() throws {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        guard data.count >= Self.headerSize, Array(data.prefix(4)) == Self.magic else { throw StoreError.badHeader }
        let dim = data.withUnsafeBytes { Int(UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: 6, as: UInt16.self))) }
        let idBytes = data.subdata(in: 12..<64).prefix { $0 != 0 }
        let foundModel = String(decoding: idBytes, as: UTF8.self)
        guard dim == dimension, foundModel == modelID else { throw StoreError.modelMismatch(found: foundModel) }

        var offsets: [UUID: UInt64] = [:]
        var dead = 0
        var offset = Self.headerSize
        let size = recordSize
        data.withUnsafeBytes { raw in
            while offset + size <= raw.count {
                let id = Self.uuid(raw, at: offset)
                if id == Self.zeroUUID { dead += 1 } else { offsets[id] = UInt64(offset) }
                offset += size
            }
        }
        self.offsets = offsets
        self.deadCount = dead
    }

    private func tombstone(at offset: UInt64, handle: FileHandle) throws {
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: Data(count: 16))
    }

    static let zeroUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    static func header(dimension: Int, modelID: String) -> Data {
        var d = Data(magic)
        withUnsafeBytes(of: version.littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(dimension).littleEndian) { d.append(contentsOf: $0) }
        d.append(contentsOf: [0, 0, 0, 0])
        var id = Array(modelID.utf8.prefix(52))
        id += [UInt8](repeating: 0, count: 52 - id.count)
        d.append(contentsOf: id)
        return d
    }

    static func bytes(of id: UUID) -> [UInt8] {
        withUnsafeBytes(of: id.uuid) { Array($0) }
    }

    static func uuid(_ raw: UnsafeRawBufferPointer, at offset: Int) -> UUID {
        var t: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &t) { dst in
            dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[offset..<(offset + 16)]))
        }
        return UUID(uuid: t)
    }
}
