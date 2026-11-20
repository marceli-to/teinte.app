import Foundation
import FoundationModels
import TeinteCore

// The @Generable mirror of `QueryFilters`. It's kept flat and enum-based so the on-device
// model has an easy job; `toFilters()` maps it to the core types.

@Generable
enum GColour: String {
    case red, orange, yellow, green, teal, blue, purple, pink, brown, black, white, grey
}

@Generable
enum GColourMode: String {
    case mostly, contains, without
}

@Generable
struct GColourFilter {
    @Guide(description: "One of the 12 colour buckets. Map synonyms: navy→blue, crimson→red, beige→brown, gray→grey, turquoise→teal, gold→yellow.")
    var colour: GColour
    @Guide(description: "mostly: the colour describes the whole image ('blue images', 'red'). contains: only part of it ('a bit of yellow', 'teal water', 'red car'). without: excluded ('no green').")
    var mode: GColourMode
}

@Generable
enum GPeople: String {
    case anyPeople, noPeople, exactly, atLeast
}

@Generable
enum GPresence: String {
    case with, without
}

@Generable
enum GOrientation: String {
    case landscape, portrait, square
}

@Generable
struct GeneratedQuery {
    @Guide(description: "Colour constraints. Empty if no colour is named. 'black and white' / monochrome is NOT a colour filter; put it in freeText.")
    var colours: [GColourFilter]
    @Guide(description: "People constraint. Omit if people aren't mentioned. 'with people' → anyPeople; 'nobody', 'no people', 'empty' → noPeople; 'two people', 'a single person' → exactly; 'groups', 'at least 3', 'crowd' → atLeast.")
    var people: GPeople?
    @Guide(description: "The number for exactly / atLeast. 'a person' = 1, 'a couple' = 2, 'groups' = 3, 'crowd' = 5.")
    var peopleCount: Int?
    @Guide(description: "Visible faces: close-ups, portraits, selfies → with; 'no faces' → without. Omit otherwise.")
    var faces: GPresence?
    @Guide(description: "Readable text, words, screenshots → with; 'no text' → without. Omit otherwise.")
    var text: GPresence?
    @Guide(description: "Image shape: vertical/tall → portrait, horizontal/wide → landscape, square. Omit unless the shape is asked for. A 'portrait' photo (of a person) or a 'landscape' (scenery) is NOT an orientation.")
    var orientation: GOrientation?
    @Guide(description: "Concrete, visible objects or scene types as single lowercase English nouns in singular: dog, beach, car, food, boat. No colours, people, moods or styles.", .maximumCount(5))
    var labels: [String]
    @Guide(description: "Everything the other fields can't express: moods, styles, light, scenes ('cozy', 'sunset over a lake', 'black and white'). Omit if nothing remains. Never repeat colours, people counts or labels here.")
    var freeText: String?
}

extension GeneratedQuery {
    func toFilters() -> QueryFilters {
        var f = QueryFilters()
        f.colours = colours.compactMap { c in
            guard let bucket = ColourBucket(rawValue: c.colour.rawValue), let mode = ColourMode(rawValue: c.mode.rawValue) else { return nil }
            return ColourFilter(bucket, mode)
        }
        switch people {
        case .anyPeople: f.people = .any
        case .noPeople: f.people = PeopleFilter.none
        case .exactly: f.people = .exactly(max(1, peopleCount ?? 1))
        case .atLeast: f.people = .atLeast(max(1, peopleCount ?? 3))
        case nil: break
        }
        f.faces = faces.flatMap { Presence(rawValue: $0.rawValue) }
        f.text = text.flatMap { Presence(rawValue: $0.rawValue) }
        f.orientation = orientation.flatMap { Orientation(rawValue: $0.rawValue) }
        f.labels = labels
        f.freeText = freeText
        return f.normalized()
    }
}

/// Parses with the on-device Foundation Models framework. One fresh session per query (no context build-up).
final class FoundationModelsParser: QueryParsing, @unchecked Sendable {
    let name = "Foundation Models"

    static var availability: SystemLanguageModel.Availability { SystemLanguageModel.default.availability }
    static var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    private let instructions = """
    You turn a short image-search request into structured filters for a photo library app. \
    Only fill a field when the request clearly asks for it. Leave out filler like "show me", "only", "images", "photos". \
    Examples:
    "show only blue images with people in it" → colours [blue mostly], people anyPeople.
    "pictures with a bit of yellow" → colours [yellow contains].
    "nothing green" → colours [green without].
    "a single person on a jetty" → people exactly 1, freeText "jetty".
    "vertical photos of dogs" → orientation portrait, labels [dog].
    "orange and pink sunset over a lake" → colours [orange contains, pink contains], freeText "sunset over a lake".
    "black and white street photos" → labels [street], freeText "black and white".
    "cozy" → freeText "cozy".
    """

    func prewarm() {
        LanguageModelSession(instructions: instructions).prewarm()
    }

    func parse(_ sentence: String) async throws -> QueryFilters {
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: sentence, generating: GeneratedQuery.self, options: GenerationOptions(samplingMode: .greedy))
        return response.content.toFilters()
    }
}
