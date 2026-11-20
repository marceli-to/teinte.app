import Foundation
import NaturalLanguage

/// The language searches are typed in. English is what the parser and the embedding model read;
/// other languages are turned into English first.
public enum SearchLanguage: String, Codable, CaseIterable, Sendable {
    case english = "en"
    case german = "de"

    /// German when German comes before English in the user's preferred languages.
    public static func systemDefault(preferred: [String] = Locale.preferredLanguages) -> SearchLanguage {
        for id in preferred {
            let code = Locale.Language(identifier: id).languageCode?.identifier
            if code == "de" { return .german }
            if code == "en" { return .english }
        }
        return .english
    }
}

/// Turns a German search into the English the rule parser reads, word by word.
///
/// This is the offline fallback: Apple's Translation framework does a better job with free text
/// ("Sonnenuntergang am See"), but it needs a language download. The glossary covers the words the
/// filters care about (colours, people, counts, looks, styles, text, shape) and common objects
/// and scenes. Unknown words stay as they are. Quoted text is never touched: it's matched against
/// the text recognised in the images.
public enum GermanGlossary {
    /// "blaue Bilder mit Menschen" → "blue images with people".
    public static func translate(_ sentence: String) -> String {
        var out: [String] = []
        for part in QuotedText.split(sentence) {
            switch part {
            case .quoted(let q): out.append("\"\(q)\"")
            case .plain(let p):
                let t = translatePlain(p)
                if !t.isEmpty { out.append(t) }
            }
        }
        return out.joined(separator: " ")
    }

    /// True when the sentence is probably German rather than English.
    /// Short queries are ambiguous ("warm"); those count as German, which is harmless because
    /// the glossary leaves English words alone.
    public static func isProbablyGerman(_ sentence: String) -> Bool {
        let tokens = tokenize(QuotedText.unquoted(sentence))
        if tokens.contains(where: { germanOnly.contains($0) }) { return true }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.english, .german]
        recognizer.processString(QuotedText.unquoted(sentence))
        let h = recognizer.languageHypotheses(withMaximum: 2)
        return (h[.english] ?? 0) < 0.8
    }

    // MARK: - Translation

    static func translatePlain(_ text: String) -> String {
        let tokens = tokenize(text)
        var out: [String] = []
        var i = 0
        tokenLoop: while i < tokens.count {
            for (phrase, english) in phrases where i + phrase.count <= tokens.count {
                if zip(phrase, tokens[i..<(i + phrase.count)]).allSatisfy({ $0.contains($1) }) {
                    out.append(english); i += phrase.count; continue tokenLoop
                }
            }
            out.append(word(tokens[i]))
            i += 1
        }
        return out.joined(separator: " ").replacingOccurrences(of: " ,", with: ",")
    }

    /// One word: the table, then adjective endings, then compounds ("Hundefotos" → "dogs images").
    static func word(_ t: String) -> String {
        if let w = words[t] { return w }
        if let a = adjective(t) { return a }
        if let id = LabelNames.germanToIdentifier[t] { return LabelResolver.displayName(id) }
        if let c = compound(t) { return c }
        if t.contains("-") {
            if let c = compound(t.replacingOccurrences(of: "-", with: "")) { return c }
            return t.split(separator: "-").map { word(String($0)) }.joined(separator: " ")
        }
        return t
    }

    /// "blaue", "dunklen", "warmes" → the stem's English.
    static func adjective(_ t: String) -> String? {
        if let a = adjectives[t] { return a }
        for ending in ["en", "em", "er", "es", "e"] where t.hasSuffix(ending) && t.count > ending.count + 2 {
            if let a = adjectives[String(t.dropLast(ending.count))] { return a }
        }
        // "orangefarben", "blaufarbig", "rötlich"
        for suffix in ["farbene", "farbenen", "farbener", "farbenes", "farben", "farbige", "farbigen", "farbig"]
            where t.hasSuffix(suffix) && t.count > suffix.count + 2 {
            if let a = adjectives[String(t.dropLast(suffix.count))] { return a }
        }
        return nil
    }

    /// "Strandfotos" → "beach images", "Blautöne" → "blue tones", "Landschaftsbilder" → "landscape images".
    static func compound(_ t: String) -> String? {
        let heads: [(String, String)] = [
            ("fotografien", "images"), ("aufnahmen", "images"), ("aufnahme", "images"), ("bildern", "images"),
            ("bilder", "images"), ("bild", "image"), ("fotos", "images"), ("foto", "image"),
            ("tönen", "tones"), ("töne", "tones"), ("ton", "tone"),
        ]
        for (head, english) in heads where t.hasSuffix(head) && t.count > head.count + 2 {
            let stem = String(t.dropLast(head.count))
            // Linking letters: Landschaft-s-bilder, Hund-e-fotos, Blume-n-bilder.
            for candidate in [stem, String(stem.dropLast()), String(stem.dropLast(2))] where candidate.count >= 3 {
                if let w = words[candidate] ?? adjectives[candidate]
                    ?? LabelNames.germanToIdentifier[candidate].map(LabelResolver.displayName) {
                    return "\(w) \(english)"
                }
            }
        }
        return nil
    }

    static func tokenize(_ text: String) -> [String] {
        let s = text.lowercased().replacingOccurrences(of: "ß", with: "ss")
        var tokens: [String] = []
        var current = ""
        for ch in s {
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "'" || ch == "+" || ch == "&" {
                current.append(ch)
            } else {
                if !current.isEmpty { tokens.append(current); current = "" }
                if ch == "," || ch == ";" { tokens.append(",") }
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    // MARK: - Tables (lowercase, ß written as ss)

    /// Each slot lists the forms it accepts.
    static let phrases: [([Set<String>], String)] = [
        ([["goldene", "goldenen", "goldener"], ["stunde"]], "golden hour"),
        ([["von"], ["oben"]], "from above"),
        ([["aus"], ["der"], ["luft", "vogelperspektive"]], "aerial"),
        ([["bei"], ["nacht"]], "at night"),
        ([["in"], ["der"], ["nacht"]], "at night"),
        ([["schwarz"], ["und"], ["weiss"]], "black and white"),
        ([["schwarz"], ["weiss"]], "black and white"),
        ([["ein"], ["bisschen", "wenig"]], "a bit of"),
        ([["ein"], ["paar"]], "a few"),
        ([["ein"], ["hauch"]], "a touch of"),
        ([["ein", "eine"], ["menge"]], "lots of"),
        ([["mehr"], ["als"]], "more than"),
        ([["hoher", "hohem", "hohen", "hohe", "starker", "starkem", "starken", "viel"], ["kontrast"]], "high contrast"),
        ([["niedriger", "niedrigem", "niedrigen", "geringer", "geringem", "geringen", "wenig", "schwacher", "schwachem"],
          ["kontrast"]], "low contrast"),
        ([["mit"], ["der"], ["aufschrift"]], "saying"),
        ([["auf"], ["dem", "der"], ["steht"]], "saying"),
        ([["mit"], ["dem"], ["wort"]], "with the word"),
        ([["im"], ["hochformat"]], "vertical"),
        ([["im"], ["querformat"]], "horizontal"),
        ([["im"], ["quadrat"]], "square"),
        ([["nur"], ["eine", "ein", "einer"], ["person"]], "only one person"),
        ([["keine", "keiner", "ohne"], ["menschenseele"]], "nobody"),
    ]

    /// Colour and look adjectives by stem; endings (-e, -en, -em, -er, -es) are stripped first.
    static let adjectives: [String: String] = [
        // Colours
        "rot": "red", "rötlich": "reddish", "purpur": "purple", "bordeaux": "burgundy", "weinrot": "burgundy",
        "orange": "orange", "orangen": "orange", "orangefarben": "orange", "apricot": "orange",
        "gelb": "yellow", "gelblich": "yellowish", "golden": "golden", "gold": "gold", "senf": "mustard",
        "grün": "green", "gruen": "green", "grünlich": "greenish", "oliv": "olive", "olivgrün": "olive",
        "mint": "mint", "mintgrün": "mint", "smaragd": "emerald", "smaragdgrün": "emerald",
        "türkis": "teal", "tuerkis": "teal", "petrol": "teal", "cyan": "cyan",
        "blau": "blue", "bläulich": "bluish", "dunkelblau": "navy", "marine": "navy", "marineblau": "navy",
        "hellblau": "blue", "himmelblau": "azure", "königsblau": "cobalt",
        "lila": "purple", "violett": "violet", "flieder": "lilac", "lavendel": "lavender",
        "rosa": "pink", "pink": "pink", "rosig": "pink", "magenta": "magenta", "lachs": "salmon",
        "braun": "brown", "bräunlich": "brownish", "beige": "beige", "khaki": "khaki", "bronze": "bronze",
        "schwarz": "black", "tiefschwarz": "jet-black",
        "weiss": "white", "weisslich": "whitish", "creme": "cream", "cremefarben": "cream", "elfenbein": "ivory",
        "grau": "grey", "gräulich": "greyish", "silber": "silver", "silbern": "silver", "anthrazit": "charcoal",
        "schwarzweiss": "black-and-white", "schwarz-weiss": "black-and-white", "einfarbig": "monochrome",
        "monochrom": "monochrome",
        // Looks
        "hell": "bright", "luftig": "airy", "sonnig": "sunny",
        "dunkel": "dark", "dunkl": "dark", "düster": "moody", "duester": "moody", "finster": "dark",
        "stimmungsvoll": "moody",
        "kontrastreich": "high-contrast", "kontrastarm": "low-contrast", "flau": "flat", "verblasst": "faded",
        "dunstig": "hazy", "diesig": "hazy",
        "lebendig": "vivid", "kräftig": "vivid", "farbenfroh": "colourful", "farbig": "colourful",
        "bunt": "colourful", "leuchtend": "vibrant", "satt": "saturated", "gesättigt": "saturated",
        "gedämpft": "muted", "blass": "muted", "pastell": "pastel", "pastellig": "pastel",
        "entsättigt": "desaturated", "zurückhaltend": "subdued",
        "warm": "warm", "wärmer": "warmer", "kalt": "cool", "kühl": "cool", "kühler": "cooler", "kälter": "cooler",
        // Styles
        "bewölkt": "overcast", "bedeckt": "overcast", "trüb": "overcast", "wolkig": "cloudy",
        "körnig": "grainy", "analog": "analog", "minimalistisch": "minimalist", "minimal": "minimal",
        "schlicht": "minimal", "nächtlich": "nighttime",
        // Shape
        "quadratisch": "square", "senkrecht": "vertical", "waagrecht": "horizontal", "waagerecht": "horizontal",
        "breit": "wide",
        // Praise
        "best": "best", "schönst": "best", "gut": "good", "toll": "great", "schön": "beautiful",
        "hochwertig": "high-quality", "lieblings": "favourite",
        // Others
        "einzeln": "single", "einzig": "single", "gemütlich": "cozy", "ruhig": "calm", "leer": "empty",
        "menschenleer": "empty", "verlassen": "deserted", "alt": "old", "neu": "new", "klein": "small",
        "gross": "large", "nass": "wet", "nebelig": "foggy", "neblig": "foggy", "verschneit": "snowy",
        "jeglich": "any", "sichtbar": "visible", "lesbar": "readable",
    ]

    static let words: [String: String] = [
        // Function words
        "mit": "with", "ohne": "without", "nicht": "not", "nichts": "nothing", "kein": "no", "keine": "no",
        "keinen": "no", "keinem": "no", "keiner": "no", "keines": "no", "niemand": "nobody", "niemanden": "nobody",
        "und": "and", "oder": "or", "aber": "but", "sowie": "and",
        "ein": "a", "eine": "a", "einen": "a", "einem": "a", "einer": "a", "eines": "a",
        "der": "the", "die": "the", "das": "the", "den": "the", "dem": "the", "des": "the",
        "von": "of", "vom": "of the", "aus": "from", "in": "in", "im": "in the", "an": "at", "am": "at the",
        "auf": "on", "über": "over", "ueber": "over", "unter": "under", "vor": "against", "hinter": "behind",
        "neben": "next to", "bei": "at", "beim": "at the", "zum": "to the", "zur": "to the", "zu": "to",
        "mehr": "more", "mindestens": "at least", "wenigstens": "at least", "min": "min",
        "genau": "exactly", "nur": "only", "bloss": "just", "alle": "all", "alles": "everything",
        "etwas": "some", "bisschen": "bit", "wenig": "little", "hauch": "touch", "spur": "trace",
        "akzent": "accent", "akzente": "accents", "akzenten": "accents", "farbtupfer": "splash",
        "hauptsächlich": "mostly", "überwiegend": "mostly", "vorwiegend": "predominantly", "meist": "mostly",
        "meistens": "mostly", "grösstenteils": "largely", "ganz": "entirely", "komplett": "completely",
        "vollständig": "completely", "völlig": "fully", "sehr": "very", "fast": "mostly", "viel": "lots",
        "zeig": "show", "zeige": "show", "zeigen": "show", "zeigt": "show", "mir": "me", "mein": "my", "meine": "my", "meinen": "my", "meiner": "my", "unsere": "our", "finde": "find",
        "such": "find", "suche": "search", "gib": "give", "ich": "i", "will": "want", "möchte": "want",
        "brauche": "need", "bitte": "please", "es": "it", "sie": "them", "diese": "these",
        "wo": "where", "welche": "which", "darauf": "on it", "drauf": "on it", "darin": "in it", "drin": "in it",
        "sind": "are", "ist": "is", "hat": "has", "haben": "have",
        // Images
        "bild": "image", "bilder": "images", "bildern": "images", "foto": "photo", "fotos": "photos",
        "aufnahme": "shot", "aufnahmen": "shots", "fotografie": "photograph", "fotografien": "photographs",
        "schnappschuss": "snap", "schnappschüsse": "snaps", "dateien": "files",
        // Colours as nouns and colour words
        "farbe": "colour", "farben": "colours", "farbton": "tone", "farbtöne": "tones", "töne": "tones",
        "ton": "tone", "tönen": "tones", "palette": "palette",
        "hintergrund": "background", "hintergründe": "backgrounds", "hintergründen": "backgrounds",
        "kulisse": "backdrop",
        // Numbers
        "eins": "one", "zwei": "two", "drei": "three", "vier": "four", "fünf": "five", "fuenf": "five",
        "sechs": "six", "sieben": "seven", "acht": "eight", "neun": "nine", "zehn": "ten", "elf": "eleven",
        "zwölf": "twelve", "zwoelf": "twelve",
        // People
        "mensch": "person", "menschen": "people", "leute": "people", "leuten": "people", "person": "person",
        "personen": "people", "frau": "woman", "frauen": "women", "mann": "man", "männer": "men",
        "maenner": "men", "männern": "men", "kind": "child", "kinder": "children", "kindern": "children",
        "junge": "boy", "jungen": "boys", "mädchen": "girl", "maedchen": "girl", "familie": "family",
        "familien": "families", "freunde": "friends", "freunden": "friends", "erwachsene": "adults",
        "gruppe": "group", "gruppen": "groups", "menschenmenge": "crowd", "menschenmengen": "crowds",
        "menge": "crowd", "paar": "couple", "paare": "couples", "pärchen": "couple", "allein": "alone",
        "alleine": "alone", "solo": "solo", "jemand": "someone", "jemandem": "someone",
        // Faces
        "gesicht": "face", "gesichter": "faces", "gesichtern": "faces", "porträt": "portrait",
        "porträts": "portraits", "portrait": "portrait", "portraits": "portraits", "selfie": "selfie",
        "selfies": "selfies", "nahaufnahme": "close-up", "nahaufnahmen": "close-up",
        // Text
        "text": "text", "texten": "text", "schrift": "writing", "wort": "word", "wörter": "words",
        "woerter": "words", "buchstaben": "letters", "beschriftung": "lettering", "beschriftungen": "lettering",
        "aufschrift": "writing", "typografie": "typography", "schild": "sign", "schilder": "signs",
        "sagt": "says", "steht": "reads", "lautet": "reads",
        // Screenshots and documents
        "bildschirmfoto": "screenshot", "bildschirmfotos": "screenshots", "screenshot": "screenshot",
        "screenshots": "screenshots", "dokument": "document", "dokumente": "documents", "dokumenten": "documents",
        "quittung": "receipt", "quittungen": "receipts", "beleg": "receipt", "belege": "receipts",
        "kassenzettel": "receipt", "rechnung": "invoice", "rechnungen": "invoices", "folie": "slide",
        "folien": "slides", "scan": "scan", "scans": "scans", "gescannt": "scanned", "gescannte": "scanned",
        // Shape
        "hochformat": "vertical", "querformat": "horizontal", "panorama": "panorama", "panoramen": "panoramas",
        "panoramabild": "panorama", "format": "format", "quadrat": "square", "quadrate": "squares",
        // Styles
        "nacht": "night", "nachts": "night", "nachtaufnahme": "night", "nachtaufnahmen": "night",
        "drohne": "drone", "drohnenaufnahme": "aerial", "drohnenaufnahmen": "aerials", "luftaufnahme": "aerial",
        "luftaufnahmen": "aerials", "luftbild": "aerial", "luftbilder": "aerials", "vogelperspektive": "bird's-eye",
        "makro": "macro", "makroaufnahme": "macro", "makroaufnahmen": "macro", "studio": "studio",
        "studiolicht": "studio light", "studiobeleuchtung": "studio lighting", "filmkorn": "film grain",
        "analogfilm": "film photo", "film": "film", "minimalismus": "minimal",
        // Praise
        "qualität": "quality", "lieblingsbilder": "favourite images", "lieblingsfotos": "favourite photos",
        // Objects and scenes
        "hund": "dog", "hunde": "dogs", "hunden": "dogs", "welpe": "puppy", "welpen": "puppies",
        "katze": "cat", "katzen": "cats", "kätzchen": "kitten", "tier": "animal", "tiere": "animals",
        "tieren": "animals", "vogel": "bird", "vögel": "birds", "voegel": "birds", "pferd": "horse",
        "pferde": "horses", "kuh": "cow", "kühe": "cows", "fisch": "fish", "fische": "fish",
        "strand": "beach", "strände": "beaches", "meer": "sea", "ozean": "ocean", "see": "lake", "seen": "lakes",
        "fluss": "river", "flüsse": "rivers", "wasser": "water", "welle": "wave", "wellen": "waves",
        "küste": "coast", "insel": "island", "hafen": "harbour", "steg": "jetty", "brücke": "bridge",
        "bruecke": "bridge", "brücken": "bridges", "boot": "boat", "boote": "boats", "booten": "boats",
        "schiff": "ship", "schiffe": "ships", "segelboot": "sailboat",
        "berg": "mountain", "berge": "mountains", "bergen": "mountains", "hügel": "hill", "huegel": "hill",
        "wald": "forest", "wälder": "forests", "baum": "tree", "bäume": "trees", "baeume": "trees",
        "bäumen": "trees", "blume": "flower", "blumen": "flowers", "blüte": "blossom", "blüten": "blossoms",
        "pflanze": "plant", "pflanzen": "plants", "gras": "grass", "wiese": "meadow", "feld": "field",
        "felder": "fields", "wüste": "desert", "schnee": "snow", "eis": "ice", "regen": "rain", "nebel": "fog",
        "himmel": "sky", "wolke": "cloud", "wolken": "clouds", "sonne": "sun", "mond": "moon", "sterne": "stars",
        "sonnenuntergang": "sunset", "sonnenuntergänge": "sunsets", "sonnenaufgang": "sunrise",
        "abendlicht": "evening light", "morgenlicht": "morning light", "abend": "evening", "morgen": "morning",
        "landschaft": "landscape", "landschaften": "landscapes", "natur": "nature",
        "stadt": "city", "städte": "cities", "strasse": "street", "strassen": "street", "gasse": "alley",
        "gebäude": "building", "gebaeude": "building", "haus": "house", "häuser": "houses", "haeuser": "houses",
        "häusern": "houses", "hochhaus": "skyscraper", "hochhäuser": "skyscrapers", "wolkenkratzer": "skyscraper",
        "kirche": "church", "turm": "tower", "burg": "castle", "schloss": "castle", "fassade": "facade",
        "fassaden": "facades", "architektur": "architecture", "fenster": "window", "tür": "door",
        "tuer": "door", "türen": "doors", "treppe": "stairs", "dach": "roof", "dächer": "roofs",
        "backstein": "brick", "ziegel": "brick", "mauer": "wall", "wand": "wall", "stein": "stone",
        "steine": "stones", "felsen": "rocks", "holz": "wood", "metall": "metal", "glas": "glass",
        "auto": "car", "autos": "cars", "wagen": "car", "fahrrad": "bicycle", "fahrräder": "bicycles",
        "velo": "bicycle", "velos": "bicycles", "zug": "train", "züge": "trains", "bus": "bus",
        "flugzeug": "airplane", "motorrad": "motorcycle",
        "essen": "food", "speise": "food", "speisen": "food", "gericht": "dish", "gerichte": "dishes",
        "mahlzeit": "meal", "kaffee": "coffee", "tasse": "cup", "kuchen": "cake", "brot": "bread",
        "obst": "fruit", "früchte": "fruit", "frucht": "fruit", "gemüse": "vegetables", "wein": "wine",
        "getränk": "drink", "getränke": "drinks", "teller": "plate",
        "tisch": "table", "stuhl": "chair", "stühle": "chairs", "sofa": "sofa", "bett": "bed",
        "zimmer": "room", "raum": "room", "küche": "kitchen", "innenraum": "interior", "innenräume": "interiors",
        "garten": "garden", "park": "park", "markt": "market", "laden": "shop", "geschäft": "shop",
        "café": "cafe", "cafe": "cafe", "restaurant": "restaurant", "büro": "office",
        "buch": "book", "bücher": "books", "laptop": "laptop", "computer": "computer", "telefon": "phone",
        "handy": "phone", "lampe": "lamp", "kerze": "candle", "kerzen": "candles", "spiegel": "mirror",
        "kleid": "dress", "kleidung": "clothes", "schuhe": "shoes", "hut": "hat", "tasche": "bag",
        "produkt": "product", "produkte": "products", "hochzeit": "wedding", "konzert": "concert",
        "party": "party", "fest": "festival", "sport": "sport", "spielplatz": "playground",
    ]

    /// Words that only occur in German, so the sentence is German whatever the recogniser thinks.
    static let germanOnly: Set<String> = {
        var s = Set<String>()
        for (k, v) in words where k != v && !englishLookalikes.contains(k) { s.insert(k) }
        for (k, v) in adjectives where k != v && !englishLookalikes.contains(k) { s.insert(k) }
        return s
    }()

    /// German keys that are also everyday English words.
    static let englishLookalikes: Set<String> = [
        "in", "an", "am", "die", "will", "see", "hell", "rot", "bad", "kind", "gift", "arm", "also", "man", "min",
        "fast", "hat", "bus", "film", "studio", "solo", "party", "park", "sport", "fest", "best", "gut", "alt",
        "neu", "toll", "ton", "rose", "laden", "wand", "markt", "format", "text", "steht", "es", "sie", "ist",
        "warm", "analog", "minimal", "palette", "porträt", "portrait", "portraits", "selfie", "selfies",
        "scan", "scans", "screenshot", "screenshots", "panorama", "computer", "laptop", "sofa", "restaurant",
        "cafe", "café", "pink", "orange", "beige", "khaki", "bronze", "cyan", "magenta", "mint", "creme",
        "petrol", "gold", "golden", "lila", "rosa", "satt", "oliv", "marine", "lavendel", "apricot", "flau",
        "breit", "bloss", "eis", "seen", "auto", "autos", "mond", "wagen", "hut",
        "fisch", "dach", "zug", "tasse", "hund", "teller", "boot", "boote", "garten", "zimmer", "raum", "glas",
    ]
}

/// Quoted text in a search: searched for in the images, verbatim, and never translated.
public enum QuotedText {
    public enum Part: Equatable { case plain(String), quoted(String) }

    static let pairs: [(String, String)] = [("\"", "\""), ("“", "”"), ("„", "“"), ("«", "»"), ("‘", "’"), ("‚", "‘")]

    /// The sentence as plain and quoted parts, in order.
    public static func split(_ sentence: String) -> [Part] {
        var parts: [Part] = []
        var rest = Substring(sentence)
        while !rest.isEmpty {
            var best: (Range<Substring.Index>, Range<Substring.Index>)?
            for (open, close) in pairs {
                guard let a = rest.range(of: open),
                      let b = rest.range(of: close, range: a.upperBound..<rest.endIndex) else { continue }
                if best == nil || a.lowerBound < best!.0.lowerBound { best = (a, b) }
            }
            guard let (a, b) = best else { parts.append(.plain(String(rest))); break }
            let before = String(rest[rest.startIndex..<a.lowerBound])
            if !before.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(.plain(before)) }
            let inner = rest[a.upperBound..<b.lowerBound].trimmingCharacters(in: .whitespaces)
            if !inner.isEmpty { parts.append(.quoted(inner)) }
            rest = rest[b.upperBound...]
        }
        return parts
    }

    /// The sentence without its quoted parts.
    public static func unquoted(_ sentence: String) -> String {
        split(sentence).compactMap { if case .plain(let p) = $0 { p } else { nil } }.joined(separator: " ")
    }

    /// The quoted parts, re-quoted with straight quotes so the parser finds them.
    public static func quotedSuffix(_ sentence: String) -> String {
        split(sentence).compactMap { if case .quoted(let q) = $0 { "\"\(q)\"" } else { nil } }.joined(separator: " ")
    }
}
