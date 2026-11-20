import Foundation
import SwiftData
import TeinteCore

/// Bump to re-analyse every image after an analysis change.
let currentAnalysisVersion = 1

@Model
final class WatchedFolder {
    @Attribute(.unique) var id: UUID
    var displayName: String
    var bookmark: Data
    var lastResolvedPath: String
    var addedAt: Date
    @Relationship(deleteRule: .cascade, inverse: \ImageRecord.folder) var images: [ImageRecord] = []

    init(id: UUID = UUID(), displayName: String, bookmark: Data, path: String) {
        self.id = id
        self.displayName = displayName
        self.bookmark = bookmark
        self.lastResolvedPath = path
        self.addedAt = .now
    }
}

enum AnalysisStatus: String, Codable {
    case pending, done, failed
}

@Model
final class ImageRecord {
    @Attribute(.unique) var id: UUID
    var folder: WatchedFolder?
    var folderID: UUID
    var relativePath: String
    var fileName: String
    var fileSize: Int64
    var contentModified: Date
    var created: Date
    var addedAt: Date
    var pixelWidth: Int = 0
    var pixelHeight: Int = 0

    var statusRaw: String = AnalysisStatus.pending.rawValue
    var failureReason: String?
    var analysisVersion: Int = 0

    var bucketShares: [Float] = []
    /// Palette as flat [L, a, b, share] × k, largest first.
    var palette: [Float] = []
    var personCount: Int = 0
    var faceCount: Int = 0
    var hasText: Bool = false
    var labels: [String] = []
    var labelConfidences: [Float] = []

    var status: AnalysisStatus {
        get { AnalysisStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    init(folder: WatchedFolder, relativePath: String, fileSize: Int64, contentModified: Date, created: Date) {
        self.id = UUID()
        self.folder = folder
        self.folderID = folder.id
        self.relativePath = relativePath
        self.fileName = (relativePath as NSString).lastPathComponent
        self.fileSize = fileSize
        self.contentModified = contentModified
        self.created = created
        self.addedAt = .now
    }

    func features(embedding: [Float]?, available: Bool) -> ImageFeatures {
        ImageFeatures(
            id: id, folderID: folderID, fileName: fileName, addedAt: addedAt,
            pixelWidth: pixelWidth, pixelHeight: pixelHeight,
            bucketShares: bucketShares.count == ColourBucket.allCases.count ? bucketShares : ColourProfile.empty.bucketShares,
            personCount: personCount, faceCount: faceCount, hasText: hasText, labels: labels,
            embedding: embedding, available: available)
    }
}
