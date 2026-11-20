import Foundation
import Testing
@testable import TeinteCore

/// Golden token IDs from Hugging Face `SiglipTokenizer` (script/convert-siglip.py writes the fixture).
@Suite("SigLIP tokenizer")
struct TokenizerTests {
    struct Golden: Decodable, CustomTestStringConvertible, Sendable {
        var text: String
        var ids: [Int32]
        var testDescription: String { text.debugDescription }
    }

    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    static let vocabURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Teinte/Resources/Models/siglip-vocab.json")

    static let goldens: [Golden] = {
        guard let data = try? Data(contentsOf: fixtures.appendingPathComponent("siglip_tokens.json")) else { return [] }
        return (try? JSONDecoder().decode([Golden].self, from: data)) ?? []
    }()

    static let tokenizer = try? SigLIPTokenizer(vocabURL: vocabURL, maxLength: 64)

    @Test(.enabled(if: tokenizer != nil && !goldens.isEmpty), arguments: goldens)
    func matchesReference(_ g: Golden) throws {
        let ids = try #require(Self.tokenizer).encode(g.text)
        #expect(ids.count == 64)
        #expect(ids == g.ids, "got \(ids.filter { $0 != 1 }) want \(g.ids.filter { $0 != 1 })")
    }

    @Test func canonicalize() {
        #expect(SigLIPTokenizer.canonicalize("  Hello,   World!  ") == "hello world")
        #expect(SigLIPTokenizer.canonicalize("IMG_2041.jpg") == "img2041jpg")
        #expect(SigLIPTokenizer.canonicalize("!!!") == "")
        #expect(SigLIPTokenizer.canonicalize("ΟΔΟΣ") == "οδοσ")       // per code point, no final sigma
        #expect(SigLIPTokenizer.canonicalize("a\u{2581}b") == "a b")
    }
}
