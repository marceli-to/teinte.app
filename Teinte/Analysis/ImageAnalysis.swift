import CoreGraphics
import Foundation
import ImageIO
import TeinteCore
import UniformTypeIdentifiers
import Vision

/// Decodes an image once at detail size (ImageIO subsampling; full-size RAWs are never decoded),
/// and derives the 512 px thumbnail from it.
enum ImageLoader {
    struct Loaded {
        /// ≤ 512 px: thumbnail cache, colour, classification, embedding.
        var thumbnail: CGImage
        /// ≤ 1536 px: people, faces and text, which need the detail.
        var detail: CGImage
        var pixelWidth: Int
        var pixelHeight: Int
    }

    static let thumbnailSide = 512
    static let detailSide = 1536

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
            kCGImageSourceThumbnailMaxPixelSize: detailSide,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let detail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        if w == 0 || h == 0 { w = detail.width; h = detail.height }
        let thumb = downscale(detail, maxSide: thumbnailSide) ?? detail
        return Loaded(thumbnail: thumb, detail: detail, pixelWidth: w, pixelHeight: h)
    }

    static func downscale(_ image: CGImage, maxSide: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > maxSide else { return image }
        let scale = Double(maxSide) / Double(longest)
        let w = max(1, Int((Double(image.width) * scale).rounded()))
        let h = max(1, Int((Double(image.height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Write a thumbnail as HEIC to the cache.
    static func writeThumbnail(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }
}

/// Everything Vision tells us about an image, in two passes: detail (people, faces, text, animals)
/// and thumbnail (classification, saliency, aesthetics).
enum VisionAnalyzer {
    struct Output {
        var personCount: Int
        var faceCount: Int
        var hasText: Bool
        /// Recognised lines, newline-separated. Capped at `maxTextLength`.
        var recognizedText: String
        /// Classification plus recognised animals and parent labels, highest confidence first.
        var labels: [(String, Float)]
        var saliency: WeightMap?
        var aesthetics: Float?
        var isUtility: Bool
    }

    /// Low on purpose: Vision often gives the object a reader would name ("building") only 0.1–0.3,
    /// while a parent ("structure") takes the high score. Embedding search catches what's still missed.
    static let labelConfidence: Float = 0.1
    static let maxLabels = 60
    static let maxTextLength = 4000
    /// Side of the saliency grid handed to the colour analyser.
    static let saliencyGrid = 32

    static func analyze(thumbnail: CGImage, detail: CGImage) async throws -> Output {
        // Detail pass.
        let detailHandler = ImageRequestHandler(detail)
        var humans = DetectHumanRectanglesRequest()
        humans.upperBodyOnly = false
        let faces = DetectFaceRectanglesRequest()
        var text = RecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = false
        text.automaticallyDetectsLanguage = true
        let animals = RecognizeAnimalsRequest()
        let (humanObs, faceObs, textObs, animalObs) = try await detailHandler.perform(humans, faces, text, animals)

        // Thumbnail pass.
        let thumbHandler = ImageRequestHandler(thumbnail)
        let classify = ClassifyImageRequest()
        let saliencyRequest = GenerateAttentionBasedSaliencyImageRequest()
        let (classes, saliencyObs) = try await thumbHandler.perform(classify, saliencyRequest)
        // Aesthetics isn't available everywhere (e.g. some VMs); it's optional.
        let aesthetics = try? await thumbHandler.perform(CalculateImageAestheticsScoresRequest())

        let people = humanObs.filter { $0.confidence >= 0.5 }.map { $0.boundingBox.cgRect }
        let faceBoxes = faceObs.filter { $0.confidence >= 0.5 }.map { $0.boundingBox.cgRect }
        let lines = textObs.compactMap { obs -> (String, Float)? in
            guard let s = obs.topCandidates(1).first?.string else { return nil }
            return (s, obs.confidence)
        }
        let hasText = lines.contains { $0.1 >= 0.5 && $0.0.filter { $0.isLetter || $0.isNumber }.count >= 3 }
        let recognized = String(lines.filter { $0.1 >= 0.3 }.map(\.0).joined(separator: "\n").prefix(maxTextLength))

        var labels = classes
            .filter { $0.confidence >= labelConfidence }
            .map { ($0.identifier.lowercased(), $0.confidence) }
        for animal in animalObs where animal.confidence >= 0.5 {
            for l in animal.labels where l.confidence >= 0.5 { labels.append((l.identifier.lowercased(), l.confidence)) }
        }
        labels = Array(LabelResolver.addingParents(labels).prefix(maxLabels))

        return Output(
            personCount: countPeople(bodies: people, faces: faceBoxes), faceCount: faceBoxes.count,
            hasText: hasText, recognizedText: recognized, labels: labels,
            saliency: weightMap(saliencyObs), aesthetics: aesthetics?.overallScore,
            isUtility: aesthetics?.isUtility ?? false)
    }

    /// Bodies, plus faces that don't sit inside any body: a close-up portrait has a face but no body,
    /// someone seen from behind has a body but no face, and most people have both.
    static func countPeople(bodies: [CGRect], faces: [CGRect]) -> Int {
        let unpaired = faces.filter { face in
            let centre = CGPoint(x: face.midX, y: face.midY)
            return !bodies.contains { $0.insetBy(dx: -0.02, dy: -0.02).contains(centre) }
        }
        return bodies.count + unpaired.count
    }

    /// Vision's 68×68 heat map, resampled to a small top-down grid.
    static func weightMap(_ obs: SaliencyImageObservation) -> WeightMap? {
        let n = saliencyGrid
        var values = [Float](repeating: 0, count: n * n)
        for j in 0..<n {
            for i in 0..<n {
                // Vision's normalised points have their origin at the bottom left.
                let p = NormalizedPoint(x: (Double(i) + 0.5) / Double(n), y: 1 - (Double(j) + 0.5) / Double(n))
                values[j * n + i] = obs.heatMap.pixel(at: p)
            }
        }
        return WeightMap(width: n, height: n, values: values).normalized()
    }

    /// The full classification taxonomy, for resolving query words to labels.
    static func taxonomy() -> Set<String> {
        let ids = (try? VNClassifyImageRequest().supportedIdentifiers()) ?? []
        return Set(ids.map { $0.lowercased() }).union(["animal"])
    }
}
