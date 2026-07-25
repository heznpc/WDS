import Foundation

/// A single occurrence of a dictionary phrase in a draft, described in exact
/// UTF-16 ranges so the accessibility bridge can act on it precisely.
///
/// Two ranges are provided because delete and replace want different spans:
/// deleting eats the phrase plus its trailing inline whitespace (so no double
/// space is left behind), while replacing substitutes only the phrase itself.
public struct DictionaryMatch: Equatable, Sendable {
    public let entryID: String
    /// The phrase itself (plus a required trailing comma, if any).
    public let phraseRange: CurrentDraftUTF16Range
    public let phraseText: String
    /// The phrase plus any immediately-following spaces/tabs, for clean deletion.
    public let deletionRange: CurrentDraftUTF16Range
    public let deletionText: String
    /// Replacement text, or "" for a delete-only entry.
    public let replacement: String
    /// Whether the matched entry is flagged for automatic, review-free apply.
    public let autoApply: Bool

    public var isReplacement: Bool { !replacement.isEmpty }
}

/// Finds occurrences of a user's registered phrases in the current draft.
///
/// The matcher is conservative in the same spirit as `CurrentDraftAnalyzer`: it
/// never splits a Latin/digit token, honours a phrase's comma requirement, and
/// requires a standalone boundary around single-character phrases so a filler
/// like "그" does not match inside "그것". Because entries are the user's own
/// explicit choices and nothing is ever applied without the review panel, it
/// does not otherwise second-guess the user.
public struct DictionaryMatcher: Sendable {
    public init() {}

    /// All non-overlapping matches in `draft`, left to right. When several
    /// phrases could match at the same spot the longest wins, mirroring the web
    /// prototype's longest-match rule.
    public func matches(in draft: String, dictionary: PhraseDictionary) -> [DictionaryMatch] {
        let source = draft as NSString
        let length = source.length
        guard length > 0 else { return [] }

        var occurrences: [(location: Int, length: Int, entry: DictionaryEntry)] = []
        for entry in dictionary.activeEntries {
            let phrase = entry.phrase as NSString
            let phraseLength = phrase.length
            guard phraseLength > 0, phraseLength <= length else { continue }

            var searchStart = 0
            while searchStart <= length - phraseLength {
                let found = source.range(
                    of: entry.phrase,
                    options: [],
                    range: NSRange(location: searchStart, length: length - searchStart)
                )
                guard found.location != NSNotFound else { break }
                if isValidOccurrence(source, range: found, entry: entry) {
                    occurrences.append((found.location, found.length, entry))
                }
                searchStart = found.location + 1
            }
        }

        // Earliest first; at the same start, the longest phrase wins.
        occurrences.sort { lhs, rhs in
            if lhs.location != rhs.location { return lhs.location < rhs.location }
            return lhs.length > rhs.length
        }

        var results: [DictionaryMatch] = []
        var cursor = 0
        for occurrence in occurrences {
            guard occurrence.location >= cursor else { continue }
            let match = buildMatch(source, occurrence: occurrence, length: length)
            results.append(match)
            cursor = match.deletionRange.location + match.deletionRange.length
        }
        return results
    }

    /// The first match adapted into the candidate shape the app pipeline already
    /// understands. A replacement entry yields a replace-style candidate over the
    /// phrase; a delete-only entry yields a delete-style candidate over the phrase
    /// plus trailing whitespace. Returns nil when nothing matches.
    public func firstCandidate(
        in draft: String,
        dictionary: PhraseDictionary
    ) -> CurrentDraftDeletionCandidate? {
        guard let match = matches(in: draft, dictionary: dictionary).first else { return nil }

        if match.isReplacement {
            return CurrentDraftDeletionCandidate(
                range: match.phraseRange,
                originalText: match.phraseText,
                reason: .userDictionaryPhrase,
                confidence: 1.0,
                safety: .high,
                replacement: match.replacement,
                autoApply: match.autoApply
            )
        }
        return CurrentDraftDeletionCandidate(
            range: match.deletionRange,
            originalText: match.deletionText,
            reason: .userDictionaryPhrase,
            confidence: 1.0,
            safety: .high,
            replacement: nil,
            autoApply: match.autoApply
        )
    }

    private func buildMatch(
        _ source: NSString,
        occurrence: (location: Int, length: Int, entry: DictionaryEntry),
        length: Int
    ) -> DictionaryMatch {
        // Fold a required trailing comma into the phrase span.
        var phraseEnd = occurrence.location + occurrence.length
        if occurrence.entry.requireComma, phraseEnd < length, isComma(source.character(at: phraseEnd)) {
            phraseEnd += 1
        }
        let phraseLocation = occurrence.location
        let phraseLength = phraseEnd - phraseLocation

        // Extend over immediately-following inline whitespace for deletion.
        var deletionEnd = phraseEnd
        while deletionEnd < length, isInlineWhitespace(source.character(at: deletionEnd)) {
            deletionEnd += 1
        }
        let deletionLength = deletionEnd - phraseLocation

        return DictionaryMatch(
            entryID: occurrence.entry.id,
            phraseRange: CurrentDraftUTF16Range(location: phraseLocation, length: phraseLength),
            phraseText: source.substring(with: NSRange(location: phraseLocation, length: phraseLength)),
            deletionRange: CurrentDraftUTF16Range(location: phraseLocation, length: deletionLength),
            deletionText: source.substring(with: NSRange(location: phraseLocation, length: deletionLength)),
            replacement: occurrence.entry.replacement,
            autoApply: occurrence.entry.autoApply
        )
    }

    private func isValidOccurrence(_ source: NSString, range: NSRange, entry: DictionaryEntry) -> Bool {
        let start = range.location
        let end = range.location + range.length

        if entry.requireComma {
            guard end < source.length, isComma(source.character(at: end)) else { return false }
        }

        // Never split an ASCII letter/digit run (protects English words).
        if start > 0, isAsciiAlphanumeric(source.character(at: start - 1)),
           isAsciiAlphanumeric(source.character(at: start)) {
            return false
        }
        if end < source.length, isAsciiAlphanumeric(source.character(at: end)),
           isAsciiAlphanumeric(source.character(at: end - 1)) {
            return false
        }

        // A single-character phrase only matches when it stands alone, so a
        // filler like "그" does not match inside a longer word.
        if entry.phrase.count == 1 {
            if start > 0, !isBoundary(source.character(at: start - 1)) { return false }
            if end < source.length, !isBoundary(source.character(at: end)) { return false }
        }
        return true
    }

    private func isComma(_ unit: unichar) -> Bool {
        unit == 0x2C || unit == 0xFF0C
    }

    private func isInlineWhitespace(_ unit: unichar) -> Bool {
        unit == 0x20 || unit == 0x09
    }

    private func isAsciiAlphanumeric(_ unit: unichar) -> Bool {
        (unit >= 0x30 && unit <= 0x39)
            || (unit >= 0x41 && unit <= 0x5A)
            || (unit >= 0x61 && unit <= 0x7A)
    }

    private func isBoundary(_ unit: unichar) -> Bool {
        // A lone surrogate means the neighbour is an astral-plane character
        // (letter, ideograph, or emoji). Treat it as a non-boundary so a
        // single-character filler glued to it is rejected, matching how its BMP
        // sibling behaves and keeping the standalone rule conservative.
        guard let scalar = Unicode.Scalar(unit) else { return false }
        if CharacterSet.whitespacesAndNewlines.contains(scalar) { return true }
        return CharacterSet.punctuationCharacters.contains(scalar)
            || CharacterSet.symbols.contains(scalar)
    }
}
