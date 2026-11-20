import Testing
@testable import TeinteCore

@Suite("Export naming")
struct ExportNamingTests {
    @Test func clashesGetSuffixes() {
        let names = ExportNaming.uniqueNames(for: ["a.jpg", "b.jpg", "a.jpg", "A.JPG", "a.jpg"])
        #expect(names == ["a.jpg", "b.jpg", "a-2.jpg", "A-3.JPG", "a-4.jpg"])
    }

    @Test func existingFilesCount() {
        let names = ExportNaming.uniqueNames(for: ["a.jpg", "c.heic"], existing: ["a.jpg", "a-2.jpg"])
        #expect(names == ["a-3.jpg", "c.heic"])
    }

    @Test func noExtensionAndDottedNames() {
        #expect(ExportNaming.uniqueNames(for: ["scan", "scan"]) == ["scan", "scan-2"])
        #expect(ExportNaming.uniqueNames(for: ["my.photo.jpg", "my.photo.jpg"]) == ["my.photo.jpg", "my.photo-2.jpg"])
    }

    @Test func aSuffixedNameDoesNotCollideWithALaterOne() {
        // "a-2.jpg" is itself a source name; the second "a.jpg" must skip to -3.
        #expect(ExportNaming.uniqueNames(for: ["a.jpg", "a-2.jpg", "a.jpg"]) == ["a.jpg", "a-2.jpg", "a-3.jpg"])
    }
}
