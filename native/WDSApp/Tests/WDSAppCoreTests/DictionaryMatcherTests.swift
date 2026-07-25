import XCTest
@testable import WDSAppCore

final class DictionaryMatcherTests: XCTestCase {
    private let matcher = DictionaryMatcher()

    private func dictionary(_ entries: DictionaryEntry...) -> PhraseDictionary {
        PhraseDictionary(entries: entries)
    }

    func testDeleteMatchEatsTrailingWhitespace() throws {
        let dict = dictionary(try DictionaryEntry(id: "1", rawPhrase: "혹시"))
        let matches = matcher.matches(in: "혹시 봐주세요", dictionary: dict)

        XCTAssertEqual(matches.count, 1)
        let match = matches[0]
        XCTAssertEqual(match.phraseText, "혹시")
        XCTAssertEqual(match.phraseRange, CurrentDraftUTF16Range(location: 0, length: 2))
        XCTAssertEqual(match.deletionText, "혹시 ")
        XCTAssertEqual(match.deletionRange, CurrentDraftUTF16Range(location: 0, length: 3))
        XCTAssertFalse(match.isReplacement)

        let candidate = try XCTUnwrap(matcher.firstCandidate(in: "혹시 봐주세요", dictionary: dict))
        XCTAssertEqual(candidate.reason, .userDictionaryPhrase)
        XCTAssertEqual(candidate.originalText, "혹시 ")
        XCTAssertEqual(candidate.range, CurrentDraftUTF16Range(location: 0, length: 3))
        XCTAssertNil(candidate.replacement)
    }

    func testReplacementMatchTargetsPhraseOnly() throws {
        let dict = dictionary(try DictionaryEntry(id: "1", rawPhrase: "봐주실 수 있을까요", replacement: "봐줘"))
        let draft = "이거 봐주실 수 있을까요"
        let candidate = try XCTUnwrap(matcher.firstCandidate(in: draft, dictionary: dict))

        XCTAssertEqual(candidate.originalText, "봐주실 수 있을까요")
        XCTAssertEqual(candidate.range, CurrentDraftUTF16Range(location: 3, length: 10))
        XCTAssertEqual(candidate.replacement, "봐줘")
    }

    func testLatinTokenIsNotSplit() throws {
        let dict = dictionary(try DictionaryEntry(id: "1", rawPhrase: "cat"))
        XCTAssertTrue(matcher.matches(in: "category theory", dictionary: dict).isEmpty)

        let matches = matcher.matches(in: "the cat sat", dictionary: dict)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].phraseRange, CurrentDraftUTF16Range(location: 4, length: 3))
    }

    func testRequireCommaOnlyMatchesBeforeComma() throws {
        let dict = dictionary(try DictionaryEntry(id: "1", rawPhrase: "그러니까,"))
        XCTAssertTrue(matcher.matches(in: "그러니까 그래서", dictionary: dict).isEmpty)

        let matches = matcher.matches(in: "그러니까, 그래서", dictionary: dict)
        XCTAssertEqual(matches.count, 1)
        // The comma is folded into the phrase span, and the trailing space is eaten.
        XCTAssertEqual(matches[0].phraseText, "그러니까,")
        XCTAssertEqual(matches[0].deletionText, "그러니까, ")
    }

    func testSingleCharacterFillerOnlyMatchesStandalone() throws {
        let dict = dictionary(try DictionaryEntry(id: "1", rawPhrase: "그"))
        XCTAssertTrue(matcher.matches(in: "그것은 사실", dictionary: dict).isEmpty)

        let matches = matcher.matches(in: "그 사람은 누구", dictionary: dict)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].phraseRange, CurrentDraftUTF16Range(location: 0, length: 1))
    }

    func testSingleCharacterFillerRejectedNextToAstralCharacter() throws {
        let dict = dictionary(try DictionaryEntry(id: "1", rawPhrase: "그"))
        // U+1D400 is an astral-plane letter (two UTF-16 units) directly before
        // 그, so the filler is not standalone and must not match.
        XCTAssertTrue(matcher.matches(in: "\u{1D400}그 사람", dictionary: dict).isEmpty)
        // A normal separator still lets it match.
        XCTAssertEqual(matcher.matches(in: "\u{1D400} 그 사람", dictionary: dict).count, 1)
    }

    func testLongestPhraseWinsAtSameStart() throws {
        let dict = dictionary(
            try DictionaryEntry(id: "short", rawPhrase: "혹시"),
            try DictionaryEntry(id: "long", rawPhrase: "혹시 가능하면")
        )
        let matches = matcher.matches(in: "혹시 가능하면 좋겠다", dictionary: dict)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].entryID, "long")
        XCTAssertEqual(matches[0].phraseText, "혹시 가능하면")
    }

    func testInactiveEntriesAreIgnored() throws {
        var entry = try DictionaryEntry(id: "1", rawPhrase: "혹시")
        entry.isActive = false
        let matches = matcher.matches(in: "혹시 봐주세요", dictionary: PhraseDictionary(entries: [entry]))
        XCTAssertTrue(matches.isEmpty)
        XCTAssertNil(matcher.firstCandidate(in: "혹시 봐주세요", dictionary: PhraseDictionary(entries: [entry])))
    }

    func testUTF16OffsetsSurviveAstralPrefix() throws {
        let dict = dictionary(try DictionaryEntry(id: "1", rawPhrase: "혹시"))
        // "😀" is two UTF-16 units, then a space, so the phrase starts at 3.
        let matches = matcher.matches(in: "😀 혹시 봐", dictionary: dict)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].phraseRange, CurrentDraftUTF16Range(location: 3, length: 2))
    }

    func testTwoNonOverlappingMatches() throws {
        let dict = dictionary(try DictionaryEntry(id: "1", rawPhrase: "음"))
        let matches = matcher.matches(in: "음 그리고 음 그래서", dictionary: dict)
        XCTAssertEqual(matches.count, 2)
    }

    func testAutoApplyPropagatesToCandidate() throws {
        let auto = dictionary(try DictionaryEntry(id: "1", rawPhrase: "혹시", autoApply: true))
        let manual = dictionary(try DictionaryEntry(id: "2", rawPhrase: "혹시"))

        let autoCandidate = try XCTUnwrap(matcher.firstCandidate(in: "혹시 봐주세요", dictionary: auto))
        XCTAssertTrue(autoCandidate.autoApply)

        let manualCandidate = try XCTUnwrap(matcher.firstCandidate(in: "혹시 봐주세요", dictionary: manual))
        XCTAssertFalse(manualCandidate.autoApply)

        // Replacement-style entries carry the flag too.
        let autoReplace = dictionary(
            try DictionaryEntry(id: "3", rawPhrase: "봐주실 수 있을까요", replacement: "봐줘", autoApply: true)
        )
        let replaceCandidate = try XCTUnwrap(
            matcher.firstCandidate(in: "이거 봐주실 수 있을까요", dictionary: autoReplace)
        )
        XCTAssertTrue(replaceCandidate.autoApply)
        XCTAssertEqual(replaceCandidate.replacement, "봐줘")
    }
}
