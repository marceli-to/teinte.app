import Testing
@testable import TeinteCore

@Suite("Ranking prompt")
struct RankingPromptTests {
    @Test("Whole sentence, boilerplate trimmed", arguments: [
        ("red building", "a photo of red building"),
        ("show me red buildings", "a photo of red buildings"),
        ("images of a teal boat on the water.", "a photo of teal boat on the water"),
    ])
    func sentence(input: String, expected: String) {
        #expect(RankingPrompt.fromSentence(input) == expected)
    }

    @Test("Negations fall back to the parsed parts", arguments: ["beach with no people", "streets without cars", "nobody on the beach"])
    func negation(input: String) {
        #expect(RankingPrompt.fromSentence(input) == nil)
    }

    @Test func parts() {
        let f = QueryFilters(colours: [.init(.red, .contains), .init(.blue, .without)], labels: ["building"])
        #expect(RankingPrompt.fromParts(filters: f, hardLabels: ["building"], softLabels: []) == "a photo of red building")
        // Colours alone rank by colour share, not by the model.
        #expect(RankingPrompt.fromParts(filters: QueryFilters(colours: [.init(.red, .mostly)]), hardLabels: [], softLabels: []) == nil)
        let edited = RankingPrompt.make(sentence: "red building", filters: f, hardLabels: ["building"], softLabels: [],
                                        sentenceIsCurrent: false)
        #expect(edited == "a photo of red building")
    }
}
