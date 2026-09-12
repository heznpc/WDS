import Foundation

/// One exact span of a draft together with the text that should replace it.
///
/// An empty `replacement` means deletion, so a single type describes both the
/// removals WDS already performed and the corrections layered on top of them.
public struct DraftSpanRepair: Equatable, Sendable {
    public let range: Range<String.Index>
    public let replacement: String

    public init(range: Range<String.Index>, replacement: String) {
        self.range = range
        self.replacement = replacement
    }
}

/// Splits a draft into word-constituent runs.
public enum DraftTokenScanner {
    /// Enumerates maximal runs of letters, digits, and `_`.
    ///
    /// Everything else — whitespace, punctuation, symbols, emoji — is a
    /// boundary. Correctors only ever inspect whole tokens, so a particle glued
    /// to the tail of an identifier or a path fragment can never be mistaken
    /// for a standalone particle.
    public static func tokenRanges(in draft: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var cursor = draft.startIndex

        while cursor < draft.endIndex {
            guard isWordConstituent(draft[cursor]) else {
                cursor = draft.index(after: cursor)
                continue
            }
            let start = cursor
            while cursor < draft.endIndex, isWordConstituent(draft[cursor]) {
                cursor = draft.index(after: cursor)
            }
            ranges.append(start..<cursor)
        }
        return ranges
    }

    public static func isWordConstituent(_ character: Character) -> Bool {
        character == "_" || character.unicodeScalars.contains { scalar in
            scalar.properties.isAlphabetic || scalar.properties.numericType != nil
        }
    }
}
