import Foundation
import Inertbox
import XCTest
import WDSTerminalAdapterCore
@testable import WDSAppCore

final class TerminalReviewProposalTests: XCTestCase {
    func testExplicitApprovalProducesAnAdapterValidatedDeletion() throws {
        let text = "씨발, 이 파서의 널 체크를 고쳐줘"
        let request = try makeRequest(text)
        let proposal = try XCTUnwrap(TerminalReviewProposal(request: request))
        let response = proposal.response(explicitlyAccepted: true, acceptanceID: "user-click")
        guard case .applied(let result) = try resolveTerminalResponse(response, for: request) else {
            return XCTFail("accepted review should be applied")
        }
        XCTAssertEqual(result.buffer, "이 파서의 널 체크를 고쳐줘")
        XCTAssertEqual(result.cursorUnicodeScalarOffset, result.buffer.unicodeScalars.count)
        XCTAssertEqual(try resolveTerminalResponse(proposal.response(explicitlyAccepted: false, acceptanceID: "keep"), for: request), .passThrough)
    }

    func testQuotesShellSyntaxAndInteractiveCLIStayUntouched() throws {
        for value in [try Inertbox.wrap("씨발, 이 파서의 널 체크를 고쳐줘"), "echo '씨발'", "rm -rf /tmp/example"] {
            XCTAssertNil(TerminalReviewProposal(request: try makeRequest(value)))
        }
        XCTAssertNil(TerminalReviewProposal(request: try makeRequest("씨발, 이 파서의 널 체크를 고쳐줘", surface: .interactiveCLI)))
    }

    private func makeRequest(_ value: String, surface: TerminalSurfaceKind = .zshZLE) throws -> TerminalResolveRequest {
        TerminalResolveRequest(requestID: "review-test", surface: TerminalSurface(kind: surface),
            snapshot: try TerminalBufferSnapshot(buffer: value, cursorUnicodeScalarOffset: value.unicodeScalars.count))
    }
}
