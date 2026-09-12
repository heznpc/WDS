import Foundation
import XCTest
@testable import WDSAppCore

final class ParticleAgreementTests: XCTestCase {
    func testObjectParticleIsRepairedInBothSafeDirections() {
        XCTAssertEqual(replacements("파일를 열어 줘"), ["파일을"])
        XCTAssertEqual(replacements("파서을 고쳐 줘"), ["파서를"])
    }

    func testInstrumentalParticleCollapsesAfterOpenAndRieulStems() {
        XCTAssertEqual(replacements("학교으로 가자"), ["학교로"])
        XCTAssertEqual(replacements("말으로 설명해 줘"), ["말로"])
    }

    func testComitativeParticleIsRepairedAfterClosedStem() {
        XCTAssertEqual(replacements("책상와 의자를 그려 줘"), ["책상과"])
    }

    func testRieulEndingIsRepairedInItsPlainPoliteAndPresumptiveForms() {
        XCTAssertEqual(replacements("정리할께"), ["정리할게"])
        XCTAssertEqual(replacements("정리할께요"), ["정리할게요"])
        XCTAssertEqual(replacements("아마 맞을껄"), ["맞을걸"])
    }

    /// The whole point of the asymmetric rule table. Each of these ends in a
    /// syllable that a symmetric 받침 rule would rewrite, and every one of them
    /// is an ordinary word.
    func testWordsThatOnlyLookLikeMistypedParticlesFailClosed() {
        let drafts = [
            "사과 두 개 주세요",
            "국가 예산을 정리해 줘",
            "경로를 다시 확인해 줘",
            "먹는 방법을 알려 줘",
            "가을 사진을 골라 줘",
            "늦가을 풍경을 그려 줘",
            "마을 지도를 만들어 줘",
            "집을 지을 계획이야",
            "껄껄 웃는 소리",
            "안와 구조를 설명해 줘",
            "앞으로 어떻게 할까",
        ]

        for draft in drafts {
            XCTAssertTrue(ParticleAgreement.repairs(in: draft).isEmpty, draft)
        }
    }

    func testStemsThatAreNotHangulAreNeverRewritten() {
        let drafts = [
            "Python을 배우자",
            "v2버전를 확인해 줘",
            "config를 고쳐 줘",
        ]

        for draft in drafts {
            XCTAssertTrue(ParticleAgreement.repairs(in: draft).isEmpty, draft)
        }
    }

    func testBareParticleHasNoStemToAgreeWith() {
        XCTAssertTrue(ParticleAgreement.repairs(in: "를 을 으로 와 께").isEmpty)
    }

    func testRepairSpanCoversTheWholeTokenSoItCanBeLocatedUniquely() throws {
        let draft = "이 파일를 저 파일과 비교해 줘"
        let repair = try XCTUnwrap(ParticleAgreement.repairs(in: draft).first)

        XCTAssertEqual(String(draft[repair.range]), "파일를")
        XCTAssertEqual(repair.replacement, "파일을")
    }

    func testAtMostOneRepairPerToken() {
        XCTAssertEqual(replacements("파일를 학교으로 보낼께"), [
            "파일을", "학교로", "보낼게",
        ])
    }

    private func replacements(_ draft: String) -> [String] {
        ParticleAgreement.repairs(in: draft).map(\.replacement)
    }
}
