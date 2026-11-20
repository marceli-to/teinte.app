import Foundation
import Translation
import TeinteCore

/// Turns a German search into English on the device, with Apple's Translation framework.
///
/// The framework needs a one-time language download, which only a SwiftUI view can ask for
/// (`.translationTask`). Until it's installed, `translate` returns nil and the caller falls back
/// to `GermanGlossary`. Quoted text is never translated: it's matched against the image's own text.
@MainActor
final class QueryTranslator {
    enum Status: Equatable { case unknown, installed, needsDownload, unsupported }

    private(set) var status: Status = .unknown
    private var cache: [String: String] = [:]
    nonisolated(unsafe) private var session: TranslationSession?

    nonisolated static let source = Locale.Language(identifier: "de")
    nonisolated static let target = Locale.Language(identifier: "en")

    /// Checks whether German → English is installed, and opens a session if it is.
    func refresh() async {
        let s = await LanguageAvailability().status(from: Self.source, to: Self.target)
        switch s {
        case .installed:
            status = .installed
            if session == nil { session = TranslationSession(installedSource: Self.source, target: Self.target) }
        case .supported: status = .needsDownload
        case .unsupported: status = .unsupported
        @unknown default: status = .unsupported
        }
    }

    /// The English for a German sentence, quoted parts kept as they are. Nil when translation
    /// isn't installed or fails.
    func translate(_ sentence: String) async -> String? {
        if let hit = cache[sentence] { return hit }
        guard status == .installed, let session else { return nil }
        let plain = QuotedText.unquoted(sentence).trimmingCharacters(in: .whitespacesAndNewlines)
        var english = ""
        if !plain.isEmpty {
            guard let response = try? await Self.run(session, plain) else { return nil }
            english = response
        }
        let result = [english, QuotedText.quotedSuffix(sentence)].filter { !$0.isEmpty }.joined(separator: " ")
        cache[sentence] = result
        return result
    }

    private nonisolated static func run(_ session: TranslationSession, _ text: String) async throws -> String {
        try await session.translate(text).targetText
    }
}
