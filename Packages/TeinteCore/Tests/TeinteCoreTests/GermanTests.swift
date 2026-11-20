import Testing
@testable import TeinteCore

/// The 20 example sentences in German, through the offline glossary. Each must give the same
/// structured filters as its English twin in `parseCases` (same order).
let germanSentences = [
    "zeig nur blaue Bilder mit Menschen",
    "rote Fotos",
    "Bilder mit ein bisschen Gelb",
    "nichts Grünes",
    "Schwarzweissfotos von Strassen",
    "Bilder im Querformat ohne Menschen",
    "genau zwei Personen",
    "Gruppen von mindestens vier Personen",
    "eine einzelne Person auf einem Steg",
    "Bildschirmfotos mit Text",
    "Bilder ohne jeglichen Text",
    "Nahaufnahmen von Gesichtern",
    "Hochformat-Fotos von Hunden",
    "orange und rosa Sonnenuntergang über einem See",
    "gemütlich",
    "überwiegend weisse minimalistische Produktfotos",
    "blau, keine Menschen und kein Text",
    "warmes Abendlicht",
    "quadratische Bilder von Essen",
    "türkises Wasser mit einer Person und einem Boot",
]

@Suite("German search")
struct GermanTests {
    let parser = RuleBasedParser(labelResolver: LabelResolver(vocabulary: testVocabulary))

    @Test("20 example sentences in German", arguments: Array(zip(germanSentences, parseCases)))
    func example(_ german: String, _ c: ParseCase) {
        let english = GermanGlossary.translate(german)
        let f = parser.parseSync(english)
        let e = parser.parseSync(c.sentence)
        #expect(f.colours == e.colours, "colours: \(english)")
        #expect(f.people == e.people, "people: \(english)")
        #expect(f.faces == e.faces, "faces: \(english)")
        #expect(f.text == e.text, "text: \(english)")
        #expect(f.orientation == e.orientation, "orientation: \(english)")
        #expect(f.labels == e.labels, "labels: \(english)")
        #expect(f.looks == e.looks, "looks: \(english)")
        #expect(f.styles == e.styles, "styles: \(english)")
        #expect(f.utility == e.utility, "utility: \(english)")
        #expect((f.freeText == nil) == (e.freeText == nil), "free text: \(f.freeText ?? "nil") vs \(e.freeText ?? "nil")")
    }

    @Test func acceptanceSentence() {
        let german = parser.parseSync(GermanGlossary.translate("blaue Bilder mit Menschen"))
        let english = parser.parseSync("blue images with people")
        #expect(german == english)
        #expect(german.chips.count == 2)
    }

    @Test func translations() {
        #expect(GermanGlossary.translate("blaue Bilder mit Menschen") == "blue images with people")
        #expect(GermanGlossary.translate("Hunde im Schnee") == "dogs in the snow")
        #expect(GermanGlossary.translate("dunkle Strassenfotos") == "dark street images")
        #expect(GermanGlossary.translate("Blautöne") == "blue tones")
        #expect(GermanGlossary.translate("Fotos zur goldenen Stunde") == "photos to the golden hour")
        #expect(GermanGlossary.translate("Großstadt") == "grossstadt") // unknown words stay (lowercased)
    }

    @Test func quotedTextIsKept() {
        #expect(GermanGlossary.translate("ein Schild mit „Offen“") == "a sign with \"Offen\"")
        let f = parser.parseSync(GermanGlossary.translate("ein Schild mit der Aufschrift „Ausverkauf“"))
        #expect(f.textQuery == "Ausverkauf")
        #expect(QuotedText.unquoted("rot «Sale» Schild").split(separator: " ") == ["rot", "Schild"])
    }

    @Test func moreGerman() {
        func p(_ s: String) -> QueryFilters { parser.parseSync(GermanGlossary.translate(s)) }
        #expect(p("kein Rot oder Orange").colours == [.init(.red, .without), .init(.orange, .without)])
        #expect(p("überwiegend blau und weiss").colours == [.init(.blue, .mostly), .init(.white, .mostly)])
        #expect(p("überwiegend blau und weiß").colours == [.init(.blue, .mostly), .init(.white, .mostly)])
        #expect(p("Produkt vor weissem Hintergrund").colours == [.init(.white, .mostly, region: .background)])
        #expect(p("Produkt auf weißem Hintergrund").freeText == "product")
        #expect(p("menschenleere Strände").people == PeopleFilter.none)
        #expect(p("mindestens 3 Personen").people == .atLeast(3))
        #expect(p("eine Frau").people == .exactly(1))
        #expect(p("Menschenmenge").people == .atLeast(5))
        #expect(p("dunkel und düster").looks == [.dark])
        #expect(p("hoher Kontrast").looks == [.highContrast])
        #expect(p("Luftaufnahmen der Küste bei Nacht").styles == [.aerial, .night])
        #expect(p("goldene Stunde").styles == [.goldenHour])
        #expect(p("Fotos schwarz-weiss").looks == [.blackAndWhite])
        #expect(p("schwarz und weiss").looks == [.blackAndWhite])
        #expect(p("meine besten Strandfotos").bestShots)
        #expect(p("ohne Bildschirmfotos").utility == .without)
        #expect(p("ein Schild mit dem Wort Liebe").textQuery == "liebe")
        #expect(p("Hochformat").orientation == .portrait)
        #expect(p("kräftige Farben").looks == [.vivid])
        #expect(GermanGlossary.translate("Leuchtturm im Nebel") == "lighthouse in the fog")
        #expect(GermanGlossary.translate("Palmenbilder") == "palm tree images")
    }

    @Test func detection() {
        #expect(GermanGlossary.isProbablyGerman("blaue Bilder mit Menschen"))
        #expect(GermanGlossary.isProbablyGerman("Hund"))
        #expect(!GermanGlossary.isProbablyGerman("blue images with people"))
        #expect(!GermanGlossary.isProbablyGerman("a single person on a jetty"))
    }

    @Test func chipTitles() {
        let de = CoreStrings.language("de"), en = CoreStrings.language("en")
        let f = parser.parseSync(GermanGlossary.translate("blaue Bilder mit Menschen"))
        #expect(f.chips.map { $0.title(de) } == ["überwiegend blau", "mit Menschen"])
        #expect(f.chips.map { $0.title(en) } == ["mostly blue", "with people"])
        func chip(_ k: FilterChip.Kind, _ l: CoreStrings = de) -> String { FilterChip(kind: k).title(l) }
        #expect(chip(.colour(.init(.white, .contains))) == "etwas Weiss")
        #expect(chip(.colour(.init(.green, .without))) == "kein Grün")
        #expect(chip(.colour(.init(.white, .mostly, region: .background))) == "Hintergrund weiss")
        #expect(chip(.people(.exactly(1))) == "1 Person")
        #expect(chip(.people(.exactly(3))) == "3 Personen")
        #expect(chip(.people(.exactly(1)), en) == "1 person")
        #expect(chip(.people(.exactly(2)), en) == "2 people")
        #expect(chip(.people(.atLeast(4)), en) == "4+ people")
        #expect(chip(.people(.atLeast(4))) == "4+ Personen")
        #expect(chip(.orientation(.portrait)) == "Hochformat")
        #expect(chip(.look(.blackAndWhite)) == "schwarz-weiss")
        #expect(chip(.style(.goldenHour)) == "goldene Stunde")
        #expect(chip(.label("dog")) == "Hund")
        #expect(chip(.freeText("gemütlich"))  == "„gemütlich“")
        #expect(chip(.freeText("cozy"), en) == "“cozy”")
        #expect(chip(.similar(SimilarSeed(id: .init(), fileName: "a.jpg"))) == "wie a.jpg")
    }

    @Test func labelNames() {
        #expect(LabelNames.displayName("dog", language: "de") == "Hund")
        #expect(LabelNames.displayName("water_body", language: "en") == "water body")
        #expect(LabelNames.displayName("some_unknown_label", language: "de") == "some unknown label")
    }

    @Test func systemDefault() {
        #expect(SearchLanguage.systemDefault(preferred: ["de-CH", "en-US"]) == .german)
        #expect(SearchLanguage.systemDefault(preferred: ["en-GB", "de-DE"]) == .english)
        #expect(SearchLanguage.systemDefault(preferred: ["fr-CH"]) == .english)
    }
}
