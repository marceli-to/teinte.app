import Foundation

/// Strings from the core's String Catalog (`Resources/Localizable.xcstrings`): chip titles, looks,
/// styles and colour names. `.current` follows the app's language; `.language("de")` is for tests.
public struct CoreStrings: @unchecked Sendable {
    let bundle: Bundle
    /// Language code of the strings, "en" or "de".
    public let language: String

    public static let current: CoreStrings = {
        let code = Bundle.module.preferredLocalizations.first ?? "en"
        return CoreStrings(bundle: .module, language: code)
    }()

    public static func language(_ code: String) -> CoreStrings {
        guard let path = Bundle.module.path(forResource: code, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return CoreStrings(bundle: .module, language: "en") }
        return CoreStrings(bundle: bundle, language: code)
    }

    public subscript(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: nil, table: nil)
    }

    /// A format from the catalog, with plural rules ("%lld people" → "1 person").
    public func format(_ key: String, _ args: any CVarArg...) -> String {
        String(format: self[key], locale: Locale(identifier: language), arguments: args)
    }

    /// The colour as an adjective: "blue", "blau".
    public func colour(_ bucket: ColourBucket) -> String { self["colour.\(bucket.rawValue)"] }

    /// The colour as a noun: "blue", "Blau".
    public func colourNoun(_ bucket: ColourBucket) -> String { self["colour.noun.\(bucket.rawValue)"] }
}

extension ColourBucket {
    /// "blue" in English, "blau" in German.
    public var title: String { CoreStrings.current.colour(self) }
}
