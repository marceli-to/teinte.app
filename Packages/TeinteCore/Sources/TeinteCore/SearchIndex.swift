import Accelerate
import Foundation

/// Everything the query pipeline needs about one image, fully in memory.
public struct ImageFeatures: Hashable, Sendable {
    public var id: UUID
    public var folderID: UUID
    public var fileName: String
    public var addedAt: Date
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var bucketShares: [Float]
    public var personCount: Int
    public var faceCount: Int
    public var hasText: Bool
    /// Vision identifiers (lowercased), including parent labels of the taxonomy.
    public var labels: [String]
    /// L2-normalised embedding, or nil if not computed yet.
    public var embedding: [Float]?
    public var available: Bool

    public init(
        id: UUID = UUID(), folderID: UUID = UUID(), fileName: String = "", addedAt: Date = .now,
        pixelWidth: Int = 1, pixelHeight: Int = 1,
        bucketShares: [Float] = ColourProfile.empty.bucketShares,
        personCount: Int = 0, faceCount: Int = 0, hasText: Bool = false, labels: [String] = [],
        embedding: [Float]? = nil, available: Bool = true
    ) {
        self.id = id; self.folderID = folderID; self.fileName = fileName; self.addedAt = addedAt
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.bucketShares = bucketShares
        self.personCount = personCount; self.faceCount = faceCount; self.hasText = hasText
        self.labels = labels; self.embedding = embedding; self.available = available
    }

    public var orientation: Orientation { Orientation(width: pixelWidth, height: pixelHeight) }

    public func share(of bucket: ColourBucket) -> Float { bucketShares[bucket.index] }
}

/// Which part of the library a query looks at (the sidebar selection).
public enum SearchScope: Hashable, Sendable {
    case all
    case addedSince(Date)
    case folder(UUID)
}

/// In-memory index: features per row plus a flat, row-major embedding matrix.
/// Value type; mutate it from one owner (an actor) and hand copies to readers.
public struct IndexSnapshot: Sendable {
    public let dimension: Int
    public private(set) var rows: [ImageFeatures] = []
    /// rows.count × dimension, zero rows where there's no embedding yet.
    public private(set) var matrix: [Float] = []
    private var rowByID: [UUID: Int] = [:]

    public init(dimension: Int) { self.dimension = dimension }

    public var count: Int { rows.count }

    public func row(for id: UUID) -> Int? { rowByID[id] }

    public mutating func upsert(_ features: ImageFeatures) {
        var f = features
        if let e = f.embedding, e.count != dimension { f.embedding = nil }
        if let r = rowByID[f.id] {
            rows[r] = f
            writeEmbedding(f.embedding, row: r)
        } else {
            rowByID[f.id] = rows.count
            rows.append(f)
            matrix.append(contentsOf: f.embedding ?? [Float](repeating: 0, count: dimension))
        }
    }

    public mutating func remove(id: UUID) {
        guard let r = rowByID.removeValue(forKey: id) else { return }
        let last = rows.count - 1
        if r != last {
            // Swap-remove keeps it O(dimension).
            rows[r] = rows[last]
            rowByID[rows[r].id] = r
            let src = last * dimension, dst = r * dimension
            for i in 0..<dimension { matrix[dst + i] = matrix[src + i] }
        }
        rows.removeLast()
        matrix.removeLast(dimension)
    }

    public mutating func setAvailability(folderID: UUID, available: Bool) {
        for i in rows.indices where rows[i].folderID == folderID { rows[i].available = available }
    }

    public mutating func removeFolder(_ folderID: UUID) {
        for id in rows.filter({ $0.folderID == folderID }).map(\.id) { remove(id: id) }
    }

    private mutating func writeEmbedding(_ e: [Float]?, row: Int) {
        let base = row * dimension
        for i in 0..<dimension { matrix[base + i] = e?[i] ?? 0 }
    }

    /// Dot products of every row with `query` (length `dimension`). One BLAS-style call.
    public func scores(for query: [Float]) -> [Float] {
        precondition(query.count == dimension)
        guard !rows.isEmpty else { return [] }
        var out = [Float](repeating: 0, count: rows.count)
        matrix.withUnsafeBufferPointer { m in
            query.withUnsafeBufferPointer { q in
                out.withUnsafeMutableBufferPointer { o in
                    vDSP_mmul(m.baseAddress!, 1, q.baseAddress!, 1, o.baseAddress!, 1,
                              vDSP_Length(rows.count), 1, vDSP_Length(dimension))
                }
            }
        }
        return out
    }

    public func embedding(row: Int) -> [Float]? { rows[row].embedding }
}

/// L2 normalisation helper shared by the embedding code paths.
public func l2Normalized(_ v: [Float]) -> [Float] {
    var sumSq: Float = 0
    vDSP_svesq(v, 1, &sumSq, vDSP_Length(v.count))
    guard sumSq > 0 else { return v }
    var scale = 1 / sumSq.squareRoot()
    var out = [Float](repeating: 0, count: v.count)
    vDSP_vsmul(v, 1, &scale, &out, 1, vDSP_Length(v.count))
    return out
}
