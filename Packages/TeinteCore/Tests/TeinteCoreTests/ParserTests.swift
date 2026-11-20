import Testing
@testable import TeinteCore

/// The 20 example sentences from PLAN.md §8.
///
/// Structured fields are asserted exactly. Free text is checked for the words that must survive
/// (`freeText: []` means "must be nil").
struct ParseCase: CustomTestStringConvertible, Sendable {
    var sentence: String
    var colours: [ColourFilter] = []
    var people: PeopleFilter? = nil
    var faces: Presence? = nil
    var text: Presence? = nil
    var orientation: Orientation? = nil
    var labels: [String] = []
    var freeText: [String] = []
    var looks: [LookFilter] = []
    var styles: [StyleTag] = []
    var utility: Presence? = nil
    var testDescription: String { sentence }
}

/// A small, fixed slice of the Vision taxonomy, so the tests don't depend on the OS version.
let testVocabulary = ["dog", "cat", "food", "boat", "beach", "street", "car", "flower", "tree", "mountain", "sky"]

let parseCases: [ParseCase] = [
    .init(sentence: "show only blue images with people in it", colours: [.init(.blue, .mostly)], people: .any),
    .init(sentence: "red photos", colours: [.init(.red, .mostly)]),
    .init(sentence: "pictures with a bit of yellow", colours: [.init(.yellow, .contains)]),
    .init(sentence: "nothing green", colours: [.init(.green, .without)]),
    .init(sentence: "black and white street photos", labels: ["street"], looks: [.blackAndWhite]),
    .init(sentence: "landscape images without people", people: PeopleFilter.none, orientation: .landscape),
    .init(sentence: "exactly two people", people: .exactly(2)),
    .init(sentence: "groups of at least four people", people: .atLeast(4)),
    .init(sentence: "a single person on a jetty", people: .exactly(1), freeText: ["jetty"]),
    .init(sentence: "screenshots with text", text: .with, utility: .with),
    .init(sentence: "images without any text", text: .without),
    .init(sentence: "close-up faces", faces: .with, freeText: ["close-up"]),
    .init(sentence: "vertical photos of dogs", orientation: .portrait, labels: ["dog"]),
    .init(sentence: "orange and pink sunset over a lake",
          colours: [.init(.orange, .contains), .init(.pink, .contains)], freeText: ["sunset over a lake"]),
    .init(sentence: "cozy", freeText: ["cozy"]),
    .init(sentence: "mostly white minimal product shots", colours: [.init(.white, .mostly)], freeText: ["product"],
          styles: [.minimal]),
    .init(sentence: "blue, no people and no text", colours: [.init(.blue, .mostly)], people: PeopleFilter.none, text: .without),
    .init(sentence: "warm evening light", freeText: ["evening light"], looks: [.warm]),
    .init(sentence: "square images of food", orientation: .square, labels: ["food"]),
    .init(sentence: "teal water with one person and a boat",
          colours: [.init(.teal, .contains)], people: .exactly(1), labels: ["boat"], freeText: ["water"]),
]

@Suite("Rule-based query parsing")
struct ParserTests {
    let parser = RuleBasedParser(labelResolver: LabelResolver(vocabulary: testVocabulary))

    @Test("20 example sentences", arguments: parseCases)
    func example(_ c: ParseCase) {
        let f = parser.parseSync(c.sentence)
        #expect(f.colours == c.colours, "colours")
        #expect(f.people == c.people, "people")
        #expect(f.faces == c.faces, "faces")
        #expect(f.text == c.text, "text")
        #expect(f.orientation == c.orientation, "orientation")
        #expect(f.labels == c.labels, "labels")
        #expect(f.looks == c.looks, "looks")
        #expect(f.styles == c.styles, "styles")
        #expect(f.utility == c.utility, "utility")
        if c.freeText.isEmpty {
            #expect(f.freeText == nil, "freeText should be nil, got \(f.freeText ?? "")")
        } else {
            for word in c.freeText {
                #expect(f.freeText?.contains(word) == true, "freeText \(f.freeText ?? "nil") should contain \(word)")
            }
            // Free text never repeats colour words or people words.
            for colour in c.colours {
                #expect(f.freeText?.contains(colour.bucket.rawValue) != true)
            }
        }
    }

    @Test func moreVariants() {
        #expect(parser.parseSync("no red or orange").colours == [.init(.red, .without), .init(.orange, .without)])
        #expect(parser.parseSync("mostly blue and white").colours == [.init(.blue, .mostly), .init(.white, .mostly)])
        #expect(parser.parseSync("grey sky").colours == [.init(.grey, .contains)])
        #expect(parser.parseSync("gray").colours == [.init(.grey, .mostly)])
        #expect(parser.parseSync("3 or more people").people == .atLeast(3))
        #expect(parser.parseSync("5+ people").people == .atLeast(5))
        #expect(parser.parseSync("a couple of people").people == .exactly(2))
        #expect(parser.parseSync("crowds in the street").people == .atLeast(5))
        #expect(parser.parseSync("nobody around").people == PeopleFilter.none)
        #expect(parser.parseSync("photos with no one in them").people == PeopleFilter.none)
        #expect(parser.parseSync("one man").people == .exactly(1))
        #expect(parser.parseSync("portraits, no text").faces == .with)
        #expect(parser.parseSync("portraits, no text").text == .without)
        #expect(parser.parseSync("portrait format").orientation == .portrait)
        #expect(parser.parseSync("mountain landscape").orientation == nil)
    }

    @Test func looksAndStyles() {
        let golden = parser.parseSync("golden hour portraits")
        #expect(golden.styles == [.goldenHour] && golden.colours.isEmpty)
        #expect(parser.parseSync("golden beach").colours == [.init(.yellow, .contains)])
        #expect(parser.parseSync("dark and moody forest").looks == [.dark])
        #expect(parser.parseSync("dark blue").looks.isEmpty)
        #expect(parser.parseSync("dark blue").colours == [.init(.blue, .mostly)])
        #expect(parser.parseSync("high contrast black and white").looks == [.blackAndWhite, .highContrast])
        #expect(parser.parseSync("warm then cool").looks == [.cool]) // opposites: the last one wins
        #expect(parser.parseSync("aerial shots of the coast at night").styles == [.aerial, .night])
        #expect(parser.parseSync("muted pastel tones").looks == [.muted])
        #expect(parser.parseSync("cool tones").freeText == nil)
    }

    @Test func textInTheImage() {
        #expect(parser.parseSync("a sign saying \"open late\"").textQuery == "open late")
        #expect(parser.parseSync("shop window with “Sale”").textQuery == "Sale")
        #expect(parser.parseSync("a sign that says exit").textQuery == "exit")
        #expect(parser.parseSync("with the word love").textQuery == "love")
        #expect(parser.parseSync("no screenshots").utility == .without)
        #expect(parser.parseSync("receipts").utility == .with)
    }

    @Test func bestShots() {
        #expect(parser.parseSync("my best photos of the beach").bestShots)
        #expect(parser.parseSync("my best photos of the beach").labels == ["beach"])
        #expect(parser.parseSync("high quality food shots").bestShots)
        #expect(!parser.parseSync("good dog").bestShots)
    }

    @Test func backgroundColours() {
        let f = parser.parseSync("product on a white background")
        #expect(f.colours == [.init(.white, .mostly, region: .background)])
        #expect(f.freeText == "product")
        #expect(parser.parseSync("portrait against a black backdrop").colours == [.init(.black, .mostly, region: .background)])
        #expect(parser.parseSync("white and grey background").colours
                == [.init(.white, .mostly, region: .background), .init(.grey, .mostly, region: .background)])
    }
}
