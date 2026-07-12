import Foundation
import XCTest
@testable import WDSWhackCore

final class GlyphTextInputTests: XCTestCase {
    func testAcceptsKoreanAndCountsExtendedGraphemeClusters() throws {
        let text = "씨발 👨‍👩‍👧‍👦 e\u{301}"
        XCTAssertEqual(try GlyphTextInput.parse(Data(text.utf8)).get(), text)
    }

    func testRejectsEmptyWhitespaceMalformedAndOversizedInput() {
        XCTAssertEqual(GlyphTextInput.parse(Data()), .failure(.empty))
        XCTAssertEqual(GlyphTextInput.parse(Data(" \n\t".utf8)), .failure(.empty))
        XCTAssertEqual(GlyphTextInput.parse(Data("\u{200D}".utf8)), .failure(.empty))
        XCTAssertEqual(GlyphTextInput.parse(Data("\u{FE0F}".utf8)), .failure(.empty))
        XCTAssertEqual(
            GlyphTextInput.parse(Data([0xC3, 0x28])),
            .failure(.invalidEncoding)
        )
        XCTAssertEqual(
            GlyphTextInput.parse(Data(repeating: 0x61, count: GlyphTextInput.maximumBytes + 1)),
            .failure(.tooLarge)
        )
    }

    func testRejectsMoreThanMaximumGraphemeClusters() {
        let text = String(repeating: "가", count: GlyphTextInput.maximumGraphemes + 1)
        XCTAssertEqual(
            GlyphTextInput.parse(Data(text.utf8)),
            .failure(.tooManyGraphemes)
        )
    }
}
