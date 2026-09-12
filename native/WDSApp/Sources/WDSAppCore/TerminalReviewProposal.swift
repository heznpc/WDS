import Foundation
import WDSTerminalAdapterCore

/// A suggestion never carries permission. Only the review action can create an
/// accepted response; the adapter independently checks the resulting range.
public struct TerminalReviewProposal: Sendable {
    public let request: TerminalResolveRequest
    public let candidate: CurrentDraftDeletionCandidate
    private let scalarStart: Int
    private let scalarLength: Int

    public init?(request: TerminalResolveRequest) {
        guard request.surface.kind == .zshZLE,
              request.snapshot.bufferSHA256 == sha256UTF8(request.snapshot.buffer),
              let candidate = CurrentDraftAnalyzer(maximumCandidates: 1).analyze(request.snapshot.buffer).first,
              !candidate.isCorrection,
              let range = Range(NSRange(location: candidate.range.location, length: candidate.range.length), in: request.snapshot.buffer),
              String(request.snapshot.buffer[range]) == candidate.originalText
        else { return nil }
        self.request = request
        self.candidate = candidate
        scalarStart = request.snapshot.buffer[..<range.lowerBound].unicodeScalars.count
        scalarLength = request.snapshot.buffer[range].unicodeScalars.count
    }

    public func response(explicitlyAccepted: Bool, acceptanceID: String) -> TerminalResolveResponse {
        guard explicitlyAccepted else { return TerminalResolveResponse(requestID: request.requestID, decision: .passThrough) }
        return TerminalResolveResponse(requestID: request.requestID, decision: .acceptedDeletion, deletion: AcceptedTerminalDeletion(
            expectedBufferSHA256: request.snapshot.bufferSHA256,
            expectedCursorUnicodeScalarOffset: request.snapshot.cursorUnicodeScalarOffset,
            rangeStartUnicodeScalarOffset: scalarStart,
            rangeLengthUnicodeScalars: scalarLength,
            expectedTargetSHA256: sha256UTF8(candidate.originalText),
            acceptanceID: acceptanceID,
            explicitlyAccepted: true
        ))
    }
}
