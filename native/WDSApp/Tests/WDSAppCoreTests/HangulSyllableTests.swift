import Foundation
import XCTest
@testable import WDSAppCore

final class HangulSyllableTests: XCTestCase {
    func testOpenSyllableReportsNoFinalConsonant() {
        for character in Array("가나다머교뒤") {
            XCTAssertEqual(
                HangulSyllable.finalConsonant(of: character),
                HangulSyllable.noFinalConsonant,
                String(character)
            )
        }
    }

    func testClosedSyllableReportsAFinalConsonant() {
        for character in Array("각간감밥있책") {
            let index = HangulSyllable.finalConsonant(of: character)
            XCTAssertNotNil(index, String(character))
            XCTAssertNotEqual(
                index,
                HangulSyllable.noFinalConsonant,
                String(character)
            )
        }
    }

    func testRieulIsDistinguishedFromEveryOtherFinalConsonant() {
        for character in Array("할갈말을") {
            XCTAssertEqual(
                HangulSyllable.finalConsonant(of: character),
                HangulSyllable.rieulFinalConsonant,
                String(character)
            )
        }

        for character in Array("합갑맘음") {
            XCTAssertNotEqual(
                HangulSyllable.finalConsonant(of: character),
                HangulSyllable.rieulFinalConsonant,
                String(character)
            )
        }
    }

    func testAnythingThatIsNotOneSyllableFailsClosed() {
        for character in Array("aZ1_ ,.😀あ") {
            XCTAssertNil(
                HangulSyllable.finalConsonant(of: character),
                String(character)
            )
        }
        // Compatibility jamo typed on their own are not syllables and carry no
        // 받침 of their own to read.
        for character in Array("ㅅㅂㄱ") {
            XCTAssertNil(
                HangulSyllable.finalConsonant(of: character),
                String(character)
            )
        }
    }

    func testCanonicallyDecomposedSyllableIsStillMeasured() throws {
        let decomposed = "각".decomposedStringWithCanonicalMapping
        XCTAssertGreaterThan(decomposed.unicodeScalars.count, 1)
        XCTAssertEqual(decomposed.count, 1)

        let character = try XCTUnwrap(decomposed.first)
        XCTAssertEqual(
            HangulSyllable.finalConsonant(of: character),
            HangulSyllable.finalConsonant(of: "각")
        )
    }

    func testMixedTokensAreNotTreatedAsHangul() {
        XCTAssertTrue(HangulSyllable.isAllSyllables("파일"[...]))
        XCTAssertFalse(HangulSyllable.isAllSyllables("v2버전"[...]))
        XCTAssertFalse(HangulSyllable.isAllSyllables("파일 이름"[...]))
        XCTAssertFalse(HangulSyllable.isAllSyllables("ㅅㅂ"[...]))
        XCTAssertFalse(HangulSyllable.isAllSyllables(""[...]))
    }
}
