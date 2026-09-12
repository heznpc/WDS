import Foundation
import XCTest
@testable import WDSAppCore

final class OrthographyRepairTests: XCTestCase {
    func testDoeAndDwaeConfusionIsRepaired() {
        XCTAssertEqual(replacements("이거 되요"), ["돼요"])
        XCTAssertEqual(replacements("안되요"), ["안돼요"])
        XCTAssertEqual(replacements("어제 됬어요"), ["됐어요"])
    }

    func testNegationPrefixConfusionIsRepairedIncludingItsSpacing() {
        XCTAssertEqual(replacements("이렇게 하면 않되니까"), ["안 되니까"])
        XCTAssertEqual(replacements("그건 않해도 괜찮아"), ["안 해도"])
    }

    func testIntentEndingIsRepaired() {
        XCTAssertEqual(replacements("지금 할려고 해"), ["하려고"])
        XCTAssertEqual(replacements("빨리 갈려면 어떡게 해"), ["가려면", "어떻게"])
    }

    func testAdverbialEndingIsRepairedOnlyForStemsThatTakeIt() {
        XCTAssertEqual(replacements("깨끗히 정리해 줘"), ["깨끗이"])
        XCTAssertTrue(OrthographyRepair.repairs(in: "조용히 정리해 줘").isEmpty)
        XCTAssertTrue(OrthographyRepair.repairs(in: "꼼꼼히 검토해 줘").isEmpty)
    }

    func testCopulaIsRepaired() {
        XCTAssertEqual(replacements("그건 아니예요"), ["아니에요"])
        XCTAssertEqual(replacements("이게 뭐에요"), ["뭐예요"])
    }

    func testVocabularyWithNoValidReadingIsRepaired() {
        XCTAssertEqual(replacements("몇일 걸려"), ["며칠"])
        XCTAssertEqual(replacements("역활을 정해 줘"), ["역할을"])
        XCTAssertEqual(replacements("어의없는 결과"), ["어이없는"])
    }

    func testCorrectSpellingsAreLeftAlone() {
        let drafts = [
            "안 돼요",
            "하려고 해",
            "어떡해 이거",
            "어떻게 할까",
            "며칠 걸려",
            "역할을 정해 줘",
            "조용히 기다려",
        ]

        for draft in drafts {
            XCTAssertTrue(OrthographyRepair.repairs(in: draft).isEmpty, draft)
        }
    }

    func testTokensThatAreNotEntirelyHangulAreOutOfReach() {
        for draft in ["userName되요", "flag_되요 확인", "되요2"] {
            XCTAssertTrue(OrthographyRepair.repairs(in: draft).isEmpty, draft)
        }
    }

    func testRepairSpanCoversTheWholeTokenEvenWhenTheFixIsInternal() throws {
        let draft = "이게 왜 안되요"
        let repair = try XCTUnwrap(OrthographyRepair.repairs(in: draft).first)

        XCTAssertEqual(String(draft[repair.range]), "안되요")
        XCTAssertEqual(repair.replacement, "안돼요")
    }

    private func replacements(_ draft: String) -> [String] {
        OrthographyRepair.repairs(in: draft).map(\.replacement)
    }
}
