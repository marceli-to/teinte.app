import CoreGraphics
import Foundation
import ImageIO
import TeinteCore
import UniformTypeIdentifiers
import Vision

/// Decodes an image once, at thumbnail size (ImageIO subsampling; full-size RAWs are never decoded).
enum ImageLoader {
    struct Loaded {
        var thumbnail: CGImage
        var pixelWidth: Int
        var pixelHeight: Int
    }

    static let thumbnailSide = 512

    static func load(_ url: URL) -> Loaded? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        var w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        var h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        if let o = props[kCGImagePropertyOrientation] as? UInt32, (5...8).contains(o) { swap(&w, &h) }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailSide,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        if w == 0 || h == 0 { w = thumb.width; h = thumb.height }
        return Loaded(thumbnail: thumb, pixelWidth: w, pixelHeight: h)
    }

    /// Write a thumbnail as HEIC to the cache.
    static func writeThumbnail(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }
}

/// People, faces, labels and text presence, in one Vision pass.
enum VisionAnalyzer {
    struct Output {
        var personCount: Int
        var faceCount: Int
        var hasText: Bool
        var labels: [(String, Float)]
    }

    /// Low on purpose: Vision often gives the object a reader would name ("building") only 0.1–0.3,
    /// while a parent ("structure") takes the high score. Embedding search catches what's still missed.
    static let labelConfidence: Float = 0.1
    static let maxLabels = 60

    static func analyze(_ image: CGImage) async throws -> Output {
        let handler = ImageRequestHandler(image)

        var humans = DetectHumanRectanglesRequest()
        humans.upperBodyOnly = false
        let faces = DetectFaceRectanglesRequest()
        let classify = ClassifyImageRequest()
        var text = RecognizeTextRequest()
        text.recognitionLevel = .fast
        text.usesLanguageCorrection = false

        let (humanObs, faceObs, classes, textObs) = try await handler.perform(humans, faces, classify, text)

        let humanCount = humanObs.filter { $0.confidence >= 0.5 }.count
        let faceCount = faceObs.filter { $0.confidence >= 0.5 }.count
        let hasText = textObs.contains { obs in
            guard obs.confidence >= 0.5, let s = obs.topCandidates(1).first?.string else { return false }
            return s.filter { $0.isLetter || $0.isNumber }.count >= 3
        }
        let labels = classes
            .filter { $0.confidence >= labelConfidence }
            .sorted { $0.confidence > $1.confidence }
            .prefix(maxLabels)
            .map { ($0.identifier.lowercased(), $0.confidence) }

        return Output(
            // Human rectangles miss close-up portraits; faces miss people seen from behind.
            personCount: max(humanCount, faceCount), faceCount: faceCount, hasText: hasText, labels: Array(labels))
    }

    /// The full classification taxonomy, for resolving query words to labels.
    static func taxonomy() -> Set<String> {
        let ids = (try? VNClassifyImageRequest().supportedIdentifiers()) ?? []
        return Set(ids.map { $0.lowercased() })
    }
}
