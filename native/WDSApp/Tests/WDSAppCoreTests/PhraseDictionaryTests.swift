import XCTest
@testable import WDSAppCore

final class PhraseDictionaryTests: XCTestCase {
    func testTrimsWhitespaceAndKeepsPlainPhrase() throws {
        let entry = try DictionaryEntry(id: "1", rawPhrase: "  안녕하세요  ")
        XCTAssertEqual(entry.phrase, "안녕하세요")
        XCTAssertFalse(entry.requireComma)
        XCTAssertFalse(entry.isReplacement)
    }

    func testTrailingCommaBecomesRequireComma() throws {
        let entry = try DictionaryEntry(id: "1", rawPhrase: "그러니까,")
        XCTAssertEqual(entry.phrase, "그러니까")
        XCTAssertTrue(entry.requireComma)
    }

    func testReplacementEntryIsMarked() throws {
        let entry = try DictionaryEntry(id: "1", rawPhrase: "봐주실 수 있을까요", replacement: "봐줘")
        XCTAssertTrue(entry.isReplacement)
        XCTAssertEqual(entry.replacement, "봐줘")
    }

    func testEmptyPhraseThrows() {
        XCTAssertThrowsError(try DictionaryEntry(id: "1", rawPhrase: "   ")) { error in
            XCTAssertEqual(error as? DictionaryEntryError, .emptyPhrase)
        }
        XCTAssertThrowsError(try DictionaryEntry(id: "1", rawPhrase: ",")) { error in
            XCTAssertEqual(error as? DictionaryEntryError, .emptyPhrase)
        }
    }

    func testNoOpReplacementThrows() {
        XCTAssertThrowsError(try DictionaryEntry(id: "1", rawPhrase: "안녕", replacement: " 안녕 ")) { error in
            XCTAssertEqual(error as? DictionaryEntryError, .noOpReplacement)
        }
    }

    func testAddDeduplicatesByPhraseAndComma() throws {
        var dictionary = PhraseDictionary()
        XCTAssertTrue(dictionary.add(try DictionaryEntry(id: "1", rawPhrase: "혹시")))
        XCTAssertFalse(dictionary.add(try DictionaryEntry(id: "2", rawPhrase: "혹시")))
        XCTAssertEqual(dictionary.entries.count, 1)
        // Same word but comma-required is a distinct entry.
        XCTAssertTrue(dictionary.add(try DictionaryEntry(id: "3", rawPhrase: "혹시,")))
        XCTAssertEqual(dictionary.entries.count, 2)
    }

    func testRemoveAndToggle() throws {
        var dictionary = PhraseDictionary()
        dictionary.add(try DictionaryEntry(id: "1", rawPhrase: "혹시"))
        dictionary.add(try DictionaryEntry(id: "2", rawPhrase: "음"))

        dictionary.setActive(false, id: "1")
        XCTAssertEqual(dictionary.activeEntries.map(\.id), ["2"])

        dictionary.remove(id: "2")
        XCTAssertEqual(dictionary.entries.map(\.id), ["1"])
        XCTAssertTrue(dictionary.activeEntries.isEmpty)
    }

    func testCodableRoundTrip() throws {
        var dictionary = PhraseDictionary()
        dictionary.add(try DictionaryEntry(id: "1", rawPhrase: "혹시"))
        dictionary.add(try DictionaryEntry(id: "2", rawPhrase: "봐주실 수 있을까요", replacement: "봐줘"))
        dictionary.add(try DictionaryEntry(id: "3", rawPhrase: "음", autoApply: true))

        let data = try JSONEncoder().encode(dictionary)
        let decoded = try JSONDecoder().decode(PhraseDictionary.self, from: data)
        XCTAssertEqual(decoded, dictionary)
        XCTAssertTrue(decoded.entries[2].autoApply)
    }

    func testDecodesLegacyEntriesWithoutAutoApplyField() throws {
        // A dictionary persisted before the autoApply field existed must keep
        // decoding (defaulting to false) instead of tripping the corrupt-blob
        // fallback and losing the user's entries.
        let legacyJSON = """
        {"entries":[{"id":"1","phrase":"혹시","replacement":"","requireComma":false,"isActive":true}]}
        """
        let decoded = try JSONDecoder().decode(PhraseDictionary.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.entries.count, 1)
        XCTAssertEqual(decoded.entries[0].phrase, "혹시")
        XCTAssertFalse(decoded.entries[0].autoApply)
    }

    func testRecursiveReplacementThrows() {
        // Replacement containing the phrase would re-create a match at the same
        // spot, so an automatic apply would edit forever.
        XCTAssertThrowsError(
            try DictionaryEntry(id: "1", rawPhrase: "부탁해", replacement: "부탁해요")
        ) { error in
            XCTAssertEqual(error as? DictionaryEntryError, .recursiveReplacement)
        }
        // A replacement merely sharing characters is fine.
        XCTAssertNoThrow(try DictionaryEntry(id: "2", rawPhrase: "봐주실 수 있을까요", replacement: "봐줘"))
    }

    func testSetAutoApplyTogglesEntry() throws {
        var dictionary = PhraseDictionary()
        dictionary.add(try DictionaryEntry(id: "1", rawPhrase: "혹시"))
        XCTAssertFalse(dictionary.entries[0].autoApply)

        dictionary.setAutoApply(true, id: "1")
        XCTAssertTrue(dictionary.entries[0].autoApply)
        dictionary.setAutoApply(false, id: "1")
        XCTAssertFalse(dictionary.entries[0].autoApply)
    }
}
