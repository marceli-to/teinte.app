import Foundation
import SwiftData
import TeinteCore

/// Bump to re-analyse every image after an analysis change.
/// 2: labels down to confidence 0.1 (was 0.3, top 20).
/// 3: look metrics, saliency-weighted soft colour buckets (k=8, 128 px), subject/background colours,
///    people/faces/text at 1536 px, recognised text, animals, parent labels, aesthetics.
let currentAnalysisVersion = 3

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
final class SavedLook {
    @Attribute(.unique) var id: UUID
    var name: String
    /// The sentence as typed.
    var query: String
    /// The filters after chip removals, so a look restores exactly without re-parsing.
    var filtersJSON: Data
    /// True if chips were removed; then the whole sentence isn't used as ranking text.
    var chipsEdited: Bool = false
    var createdAt: Date
    var sortIndex: Int

    init(name: String, query: String, filtersJSON: Data, chipsEdited: Bool, sortIndex: Int) {
        self.id = UUID()
        self.name = name
        self.query = query
        self.filtersJSON = filtersJSON
        self.chipsEdited = chipsEdited
        self.createdAt = .now
        self.sortIndex = sortIndex
    }
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
    var subjectShares: [Float] = []
    var backgroundShares: [Float] = []
    /// [brightness, contrast, saturation, warmth, colourfulShare]; empty before analysis v3.
    var lookMetrics: [Float] = []
    /// As recognised (original case), lines separated by newlines.
    var recognizedText: String = ""
    var aesthetics: Float?
    var isUtility: Bool = false

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
            palette: paletteEntries, embedding: embedding, available: available,
            subjectShares: subjectShares, backgroundShares: backgroundShares, look: look,
            recognizedText: ImageFeatures.foldForSearch(recognizedText), aesthetics: aesthetics, isUtility: isUtility)
    }

    var look: LookMetrics {
        get {
            guard lookMetrics.count == 5 else { return .neutral }
            return LookMetrics(brightness: lookMetrics[0], contrast: lookMetrics[1], saturation: lookMetrics[2],
                               warmth: lookMetrics[3], colourfulShare: lookMetrics[4])
        }
        set { lookMetrics = [newValue.brightness, newValue.contrast, newValue.saturation, newValue.warmth, newValue.colourfulShare] }
    }

    var paletteEntries: [PaletteEntry] {
        stride(from: 0, to: palette.count - 3, by: 4).map { i in
            let c = OKLab(l: palette[i], a: palette[i + 1], b: palette[i + 2])
            return PaletteEntry(colour: c, share: palette[i + 3], bucket: ColourBucketMapper.bucket(for: c))
        }
    }
}
