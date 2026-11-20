import FoundationModels
import Testing
import TeinteCore
@testable import Teinte

/// Opt-in: runs the 20 example sentences through the on-device model and reports agreement.
/// Skipped when Apple Intelligence isn't available (e.g. CI). The model isn't deterministic across
/// OS updates, so this reports a score rather than failing on single sentences.
@Suite("Foundation Models parser (opt-in)", .enabled(if: FoundationModelsParser.isAvailable))
struct FoundationModelsParserTests {
    static let sentences = [
        "show only blue images with people in it", "red photos", "pictures with a bit of yellow", "nothing green",
        "black and white street photos", "landscape images without people", "exactly two people",
        "groups of at least four people", "a single person on a jetty", "screenshots with text",
        "images without any text", "close-up faces", "vertical photos of dogs",
        "orange and pink sunset over a lake", "cozy", "mostly white minimal product shots",
        "blue, no people and no text", "warm evening light", "square images of food",
        "teal water with one person and a boat",
    ]

    @Test func agreementWithRuleParser() async throws {
        let fm = FoundationModelsParser()
        let rules = RuleBasedParser(labelResolver: LabelResolver(vocabulary: ["dog", "food", "boat", "street"]))
        var agree = 0
        var report: [String] = []
        for s in Self.sentences {
            let a = try await fm.parse(s)
            let b = rules.parseSync(s)
            let same = a.colours == b.colours && a.people == b.people && a.text == b.text
                && a.faces == b.faces && a.orientation == b.orientation
            if same { agree += 1 }
            report.append("\(same ? "✓" : "✗") \(s)\n    fm:    \(a.summary)\n    rules: \(b.summary)")
        }
        print("Foundation Models agreement: \(agree)/\(Self.sentences.count)\n" + report.joined(separator: "\n"))
        #expect(agree >= 14, "FM parser agrees with the reference on fewer than 14 of 20 sentences")
    }
}
