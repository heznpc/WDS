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

        let data = try JSONEncoder().encode(dictionary)
        let decoded = try JSONDecoder().decode(PhraseDictionary.self, from: data)
        XCTAssertEqual(decoded, dictionary)
    }
}
