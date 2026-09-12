import Foundation
import Inertbox
import XCTest
@testable import WDSAppCore

final class QuotedDraftTests: XCTestCase {
    private let analyzer = CurrentDraftAnalyzer(maximumCandidates: 3, includesCorrections: true)

    func testOnlyUserWordsAroundTheQuoteCanBeCorrected() throws {
        let quoted = try Inertbox.wrap("씨발 파일를 열어 줘")
        let user = "이 파일를 열어 주세요."
        let draft = quoted + user
        let candidates = analyzer.analyze(draft)
        let correction = try XCTUnwrap(candidates.first(where: { $0.replacementText == "파일을" }))
        XCTAssertGreaterThanOrEqual(correction.range.location, (quoted as NSString).length)
        let edited = (draft as NSString).replacingCharacters(
            in: NSRange(location: correction.range.location, length: correction.range.length),
            with: correction.replacementText
        )
        XCTAssertTrue(edited.hasPrefix(quoted))
        XCTAssertEqual(try Inertbox.protectedRanges(in: edited).count, 1)
    }

    func testQuotedTextIsNeverOfferedAndDamageRefusesTheWholeDraft() throws {
        let quoted = try Inertbox.wrap("씨발, 파일를 열어 주세요.")
        XCTAssertTrue(analyzer.analyze(quoted).isEmpty)
        XCTAssertTrue(analyzer.analyze(quoted.replacingOccurrences(of: "파일를", with: "파일을") + "파일를 열어 주세요.").isEmpty)
    }
}
