import Foundation

/// German names for Vision's classification identifiers.
///
/// Covers the ~260 labels that come up most in a real library; anything else shows its English name.
/// The same table lets German searches name a label ("Leuchtturm" → lighthouse).
public enum LabelNames {
    /// "dog" → "Hund" in German, "dog" in English. `language` is a language code ("de", "en").
    public static func displayName(_ identifier: String, language: String) -> String {
        if language == "de", let name = german[identifier] { return name }
        return LabelResolver.displayName(identifier)
    }

    /// Lowercased German name (ß as ss) → identifier.
    static let germanToIdentifier: [String: String] = {
        var out: [String: String] = [:]
        for (id, name) in german.sorted(by: { $0.key < $1.key }) {
            let key = name.lowercased().replacingOccurrences(of: "ß", with: "ss")
            if out[key] == nil { out[key] = id }
        }
        return out
    }()

    static let german: [String: String] = [
        "outdoor": "draußen", "sky": "Himmel", "structure": "Bauwerk", "land": "Land", "liquid": "Flüssigkeit",
        "cloudy": "bewölkt", "water": "Wasser", "blue_sky": "blauer Himmel", "plant": "Pflanze",
        "water_body": "Gewässer", "people": "Menschen", "grass": "Gras", "rocks": "Felsen", "adult": "Erwachsener",
        "hill": "Hügel", "machine": "Maschine", "wood_processed": "Holz (verarbeitet)", "building": "Gebäude",
        "sunset_sunrise": "Sonnenuntergang", "ocean": "Ozean", "conveyance": "Verkehrsmittel", "material": "Material",
        "foliage": "Laub", "road": "Straße", "portal": "Tor", "animal": "Tier", "haze": "Dunst",
        "night_sky": "Nachthimmel", "frozen": "gefroren", "fence": "Zaun", "forest": "Wald", "vehicle": "Fahrzeug",
        "mountain": "Berg", "vegetation": "Vegetation", "consumer_electronics": "Elektronik",
        "skyscraper": "Hochhaus", "cityscape": "Stadtbild", "path": "Weg", "bridge": "Brücke", "food": "Essen",
        "clothing": "Kleidung", "window": "Fenster", "utensil": "Utensil", "mammal": "Säugetier",
        "recreation": "Freizeit", "lake": "See", "tableware": "Geschirr", "snow": "Schnee",
        "wood_natural": "Holz", "furniture": "Möbel", "computer": "Computer", "daytime": "Tag",
        "document": "Dokument", "arch": "Bogen", "laptop": "Laptop", "street": "Straße",
        "agriculture": "Landwirtschaft", "art": "Kunst", "evergreen": "Nadelbaum", "branch": "Ast",
        "railroad": "Eisenbahn", "camera": "Kamera", "road_other": "Straße", "apartment": "Wohnhaus",
        "automobile": "Auto", "underwater": "Unterwasser", "table": "Tisch", "crowd": "Menschenmenge",
        "track_rail": "Gleis", "textile": "Textil", "pier": "Pier", "brick": "Backstein", "desert": "Wüste",
        "fruit": "Obst", "flower": "Blume", "book": "Buch", "tree": "Baum", "cliff": "Klippe", "sun": "Sonne",
        "cord": "Kabel", "dirt_road": "Feldweg", "farm": "Bauernhof", "domicile": "Wohnhaus", "dog": "Hund",
        "alley": "Gasse", "bicycle": "Fahrrad", "decoration": "Dekoration", "light": "Licht", "storm": "Sturm",
        "house_single": "Haus", "fire": "Feuer", "raw_glass": "Glas", "sport": "Sport", "canine": "Hund",
        "tool": "Werkzeug", "cup": "Tasse", "footwear": "Schuhe", "beach": "Strand", "dock": "Anlegestelle",
        "waterways": "Wasserweg", "balcony": "Balkon", "sand": "Sand", "aircraft": "Flugzeug",
        "palm_tree": "Palme", "ungulates": "Huftiere", "berry": "Beere", "aurora": "Polarlicht",
        "container": "Behälter", "dashboard": "Armaturenbrett", "bowl": "Schale", "stairs": "Treppe",
        "jeans": "Jeans", "jellyfish": "Qualle", "sand_dune": "Düne", "moss": "Moos", "drink": "Getränk",
        "car": "Auto", "trail": "Pfad", "tunnel": "Tunnel", "shoes": "Schuhe", "lamppost": "Laterne",
        "bird": "Vogel", "dial": "Zifferblatt", "timepiece": "Uhr", "mug": "Becher", "tower": "Turm",
        "typewriter": "Schreibmaschine", "interior_room": "Innenraum", "cactus": "Kaktus",
        "performance": "Auftritt", "coral_reef": "Korallenriff", "coffee": "Kaffee", "pyrotechnics": "Feuerwerk",
        "seasonings": "Gewürze", "tramway": "Straßenbahn", "jacket": "Jacke", "amusement_park": "Freizeitpark",
        "park": "Park", "rope": "Seil", "wheel": "Rad", "printed_page": "Druckseite", "straw_hay": "Stroh",
        "escalator": "Rolltreppe", "dome": "Kuppel", "feline": "Katze", "bench": "Bank", "vegetable": "Gemüse",
        "balloon_hotair": "Heißluftballon", "handwriting": "Handschrift", "raspberry": "Himbeere",
        "music": "Musik", "musical_instrument": "Musikinstrument", "lighthouse": "Leuchtturm", "lily": "Lilie",
        "bear": "Bär", "airplane": "Flugzeug", "optical_equipment": "Optik", "headgear": "Kopfbedeckung",
        "hat": "Hut", "door": "Tür", "pug": "Mops", "herb": "Kraut", "ferris_wheel": "Riesenrad",
        "sneaker": "Turnschuh", "tire": "Reifen", "rainbow": "Regenbogen", "citrus_fruit": "Zitrusfrucht",
        "tulip": "Tulpe", "flag": "Flagge", "gull": "Möwe", "roof": "Dach", "clock": "Uhr", "watch": "Armbanduhr",
        "watersport": "Wassersport", "canyon": "Schlucht", "grape": "Traube", "deer": "Hirsch", "ivy": "Efeu",
        "lightning": "Blitz", "orchid": "Orchidee", "volcano": "Vulkan", "license_plate": "Nummernschild",
        "concert": "Konzert", "computer_keyboard": "Tastatur", "cycling": "Radfahren", "coyote_wolf": "Wolf",
        "sparkler": "Wunderkerze", "decorative_plant": "Zierpflanze", "coffee_bean": "Kaffeebohne",
        "seed": "Samen", "shore": "Ufer", "maple_tree": "Ahorn", "streetcar": "Straßenbahn", "boat": "Boot",
        "watercraft": "Wasserfahrzeug", "pen": "Stift", "celebration": "Feier", "ceremony": "Zeremonie",
        "wedding": "Hochzeit", "beanie": "Mütze", "gamepad": "Gamepad", "toy": "Spielzeug", "sign": "Schild",
        "fireworks": "Feuerwerk", "flame": "Flamme", "vase": "Vase", "frame": "Rahmen", "statue": "Statue",
        "shrub": "Strauch", "luggage": "Gepäck", "child": "Kind", "dandelion": "Löwenzahn",
        "sports_equipment": "Sportgerät", "skating": "Skaten", "skatepark": "Skatepark", "headphones": "Kopfhörer",
        "lifesaver": "Rettungsring", "chairlift": "Sessellift", "van": "Lieferwagen", "spiderweb": "Spinnennetz",
        "rose": "Rose", "waterfall": "Wasserfall", "bookshelf": "Bücherregal", "leopard": "Leopard",
        "salad": "Salat", "geyser": "Geysir", "mushroom": "Pilz", "fork": "Gabel", "map": "Karte",
        "umbrella": "Schirm", "chair": "Stuhl", "folding_chair": "Klappstuhl", "pelican": "Pelikan",
        "blossom": "Blüte", "piano": "Klavier", "drinking_glass": "Trinkglas", "daisy": "Gänseblümchen",
        "entertainer": "Künstler", "singer": "Sänger", "raptor": "Greifvogel", "vulture": "Geier",
        "sportscar": "Sportwagen", "chart": "Diagramm", "diagram": "Diagramm", "computer_monitor": "Bildschirm",
        "plate": "Teller", "bar": "Bar", "sunglasses": "Sonnenbrille", "axe": "Axt", "hoodie": "Kapuzenpulli",
        "blizzard": "Schneesturm", "strawberry": "Erdbeere", "toad": "Kröte", "pool": "Pool",
        "tachometer": "Drehzahlmesser", "chalkboard": "Tafel", "boot": "Stiefel", "wetland": "Feuchtgebiet",
        "train_station": "Bahnhof", "arthropods": "Gliederfüßer", "cat": "Katze", "horse": "Pferd",
        "cow": "Kuh", "sheep": "Schaf", "fish": "Fisch", "insect": "Insekt", "butterfly": "Schmetterling",
        "river": "Fluss", "sea": "Meer", "island": "Insel", "harbour": "Hafen", "harbor": "Hafen",
        "church": "Kirche", "castle": "Burg", "garden": "Garten", "kitchen": "Küche", "bread": "Brot",
        "cake": "Kuchen", "wine": "Wein", "candle": "Kerze", "mirror": "Spiegel", "train": "Zug", "bus": "Bus",
        "motorcycle": "Motorrad", "ship": "Schiff", "sailboat": "Segelboot", "field": "Feld",
        "meadow": "Wiese", "fog": "Nebel", "rain": "Regen", "moon": "Mond", "cloud": "Wolke", "person": "Person",
        "baby": "Baby", "storefront": "Ladenfront", "barn": "Scheune", "shed": "Schuppen", "windmill": "Windmühle",
        "clock_tower": "Uhrturm", "belltower": "Glockenturm", "graffiti": "Graffiti", "screenshot": "Screenshot",
    ]
}
