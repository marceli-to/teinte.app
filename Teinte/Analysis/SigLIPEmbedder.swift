import CoreGraphics
import CoreML
import Foundation
import TeinteCore

/// An image–text embedding model. Outputs are L2-normalised.
protocol EmbeddingModel: Sendable {
    var modelID: String { get }
    var dimension: Int { get }
    var calibration: MatchCalibration { get }
    func embed(image: CGImage) async throws -> [Float]
    func embed(text: String) async throws -> [Float]
}

/// SigLIP base patch16-224 (Apache 2.0), converted to Core ML by `script/convert-siglip.py`.
final class SigLIPEmbedder: EmbeddingModel, @unchecked Sendable {
    struct Meta: Decodable {
        var modelID: String
        var dimension: Int
        var imageSize: Int
        var maxTokens: Int
        var logitScale: Float
        var logitBias: Float
    }

    let modelID: String
    let dimension: Int
    let calibration: MatchCalibration

    private let imageModel: MLModel
    private let textModel: MLModel
    private let tokenizer: SigLIPTokenizer
    private let imageConstraint: MLImageConstraint
    private let maxTokens: Int

    private let textCache = NSCache<NSString, NSArray>()

    enum LoadError: Error { case missing(String) }

    /// Loads from the app bundle. Returns nil (with a reason) when the models haven't been generated yet.
    static func loadFromBundle() -> Result<SigLIPEmbedder, Error> {
        do {
            let b = Bundle.main
            guard let image = b.url(forResource: "SigLIPImage", withExtension: "mlmodelc") else { throw LoadError.missing("SigLIPImage.mlmodelc") }
            guard let text = b.url(forResource: "SigLIPText", withExtension: "mlmodelc") else { throw LoadError.missing("SigLIPText.mlmodelc") }
            guard let meta = b.url(forResource: "siglip-meta", withExtension: "json") else { throw LoadError.missing("siglip-meta.json") }
            guard let vocab = b.url(forResource: "siglip-vocab", withExtension: "json") else { throw LoadError.missing("siglip-vocab.json") }
            return .success(try SigLIPEmbedder(imageURL: image, textURL: text, metaURL: meta, vocabURL: vocab))
        } catch {
            return .failure(error)
        }
    }

    init(imageURL: URL, textURL: URL, metaURL: URL, vocabURL: URL) throws {
        let meta = try JSONDecoder().decode(Meta.self, from: Data(contentsOf: metaURL))
        modelID = meta.modelID
        dimension = meta.dimension
        maxTokens = meta.maxTokens
        calibration = .generic // tuned for SigLIP base; see MatchCalibration

        let config = MLModelConfiguration()
        config.computeUnits = .all
        imageModel = try MLModel(contentsOf: imageURL, configuration: config)
        // The Neural Engine compiler rejects the text encoder; skip the failed attempt at load.
        let textConfig = MLModelConfiguration()
        textConfig.computeUnits = .cpuAndGPU
        textModel = try MLModel(contentsOf: textURL, configuration: textConfig)
        tokenizer = try SigLIPTokenizer(vocabURL: vocabURL, maxLength: meta.maxTokens)

        guard let c = imageModel.modelDescription.inputDescriptionsByName["image"]?.imageConstraint else {
            throw LoadError.missing("image input")
        }
        imageConstraint = c
        textCache.countLimit = 256
    }

    func embed(image: CGImage) async throws -> [Float] {
        // SigLIP's processor resizes to 224×224 without keeping the aspect ratio: scaleFill.
        let value = try MLFeatureValue(
            cgImage: image, constraint: imageConstraint,
            options: [.cropAndScale: VNImageCropAndScaleOptionScaleFill])
        let input = try MLDictionaryFeatureProvider(dictionary: ["image": value])
        let out = try await imageModel.prediction(from: input)
        return l2Normalized(Self.floats(out.featureValue(for: "embedding")?.multiArrayValue))
    }

    func embed(text: String) async throws -> [Float] {
        if let cached = textCache.object(forKey: text as NSString) as? [Float] { return cached }
        let ids = tokenizer.encode(text)
        let array = try MLMultiArray(shape: [1, NSNumber(value: maxTokens)], dataType: .int32)
        for (i, id) in ids.enumerated() { array[i] = NSNumber(value: id) }
        let input = try MLDictionaryFeatureProvider(dictionary: ["input_ids": MLFeatureValue(multiArray: array)])
        let out = try await textModel.prediction(from: input)
        let v = l2Normalized(Self.floats(out.featureValue(for: "embedding")?.multiArrayValue))
        textCache.setObject(v as NSArray, forKey: text as NSString)
        return v
    }

    private static func floats(_ array: MLMultiArray?) -> [Float] {
        guard let array else { return [] }
        let n = array.count
        switch array.dataType {
        case .float32:
            return array.withUnsafeBufferPointer(ofType: Float.self) { Array($0.prefix(n)) }
        case .float16:
            return array.withUnsafeBufferPointer(ofType: Float16.self) { $0.prefix(n).map(Float.init) }
        default:
            return (0..<n).map { array[$0].floatValue }
        }
    }
}

/// VNImageCropAndScaleOption.scaleFill without importing Vision's old API here.
private let VNImageCropAndScaleOptionScaleFill = NSNumber(value: 2)
