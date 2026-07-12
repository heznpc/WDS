import CryptoKit
import Foundation

/// A UTF-16 range suitable for macOS Accessibility APIs.
public struct SessionPatternTextRange: Equatable, Sendable {
    public let location: Int
    public let length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

/// A local-only suggestion. Producing one never edits text or invokes a model.
public struct SessionPatternSuggestion: Equatable, Sendable {
    public let displayPhrase: String
    public let exactDeleteText: String
    public let range: SessionPatternTextRange
    public let observationCount: Int
    public let distinctContextCount: Int

    public init(
        displayPhrase: String,
        exactDeleteText: String,
        range: SessionPatternTextRange,
        observationCount: Int,
        distinctContextCount: Int
    ) {
        self.displayPhrase = displayPhrase
        self.exactDeleteText = exactDeleteText
        self.range = range
        self.observationCount = observationCount
        self.distinctContextCount = distinctContextCount
    }
}

public struct SessionPatternSummary: Equatable, Sendable {
    public let observedDraftCount: Int
    public let eligibleDraftCount: Int
    public let retainedCandidateCount: Int
    public let readyCandidateCount: Int
    public let distinctContextCount: Int
    public let duplicateContextObservationCount: Int

    public init(
        observedDraftCount: Int,
        eligibleDraftCount: Int,
        retainedCandidateCount: Int,
        readyCandidateCount: Int,
        distinctContextCount: Int,
        duplicateContextObservationCount: Int
    ) {
        self.observedDraftCount = observedDraftCount
        self.eligibleDraftCount = eligibleDraftCount
        self.retainedCandidateCount = retainedCandidateCount
        self.readyCandidateCount = readyCandidateCount
        self.distinctContextCount = distinctContextCount
        self.duplicateContextObservationCount = duplicateContextObservationCount
    }
}

/// Learns only short, session-scoped sentence openings. The retained state is
/// limited to a display phrase, counters, and salted SHA-256 digests of suffixes.
/// It has no persistence or networking behavior.
public final class SessionPatternDetector: @unchecked Sendable {
    private enum CandidateKind: String {
        case comma
        case plain

        var minimumObservations: Int {
            switch self {
            case .comma: return 2
            case .plain: return 3
            }
        }
    }

    private struct CandidateRecord {
        let displayPhrase: String
        let kind: CandidateKind
        let tokenCount: Int
        var observationCount: Int
        var contextDigests: Set<String>

        var isReady: Bool {
            observationCount >= kind.minimumObservations && contextDigests.count >= 2
        }
    }

    private struct ExtractedCandidate {
        let displayPhrase: String
        let normalizedPhrase: String
        let kind: CandidateKind
        let tokenCount: Int
        let exactDeleteText: String
        let range: SessionPatternTextRange
        let normalizedContext: String
    }

    private struct TokenSpan {
        let start: String.Index
        let end: String.Index
    }

    private static let maximumDisplayCharacters = 24
    /// Keeps a single extended grapheme with excessive combining marks from
    /// bypassing the human-readable 24-character limit.
    private static let maximumDisplayUTF16Units = 48
    private static let maximumDisplayUTF8Bytes = 192
    private static let maximumRetainedCandidates = 128
    private static let maximumContextsPerCandidate = 64

    private let lock = NSLock()
    private var salt: Data
    private var generation = UUID()
    /// Keyed by a salted digest so the normalized phrase is not retained twice.
    private var records: [String: CandidateRecord] = [:]
    private var observedDraftCount = 0
    private var eligibleDraftCount = 0
    private var duplicateContextObservationCount = 0

    public init() {
        salt = SessionPatternDetector.makeSalt()
    }

    /// Observes a draft only after the caller considers it complete (for
    /// example, after a send action). No source or suffix text is retained.
    public func observeCompletedDraft(_ draft: String) {
        lock.lock()
        let observedGeneration = generation
        lock.unlock()

        let candidates = Self.extractCandidates(from: draft)

        lock.lock()
        defer { lock.unlock() }
        // A concurrent reset is a hard privacy boundary: work extracted from
        // the previous session must not be committed into the new one.
        guard generation == observedGeneration else { return }

        observedDraftCount = Self.saturatingIncrement(observedDraftCount)
        guard !candidates.isEmpty else { return }
        eligibleDraftCount = Self.saturatingIncrement(eligibleDraftCount)

        for candidate in candidates {
            let key = digest(domain: "candidate", value: candidate.normalizedPhrase)
            let contextDigest = digest(
                domain: "context:\(key)",
                value: candidate.normalizedContext
            )

            if var record = records[key] {
                record.observationCount = Self.saturatingIncrement(record.observationCount)
                let wasDuplicate = record.contextDigests.contains(contextDigest)
                if !wasDuplicate,
                   record.contextDigests.count < Self.maximumContextsPerCandidate {
                    record.contextDigests.insert(contextDigest)
                }
                if wasDuplicate {
                    duplicateContextObservationCount = Self.saturatingIncrement(
                        duplicateContextObservationCount
                    )
                }
                records[key] = record
            } else if records.count < Self.maximumRetainedCandidates {
                records[key] = CandidateRecord(
                    displayPhrase: candidate.displayPhrase,
                    kind: candidate.kind,
                    tokenCount: candidate.tokenCount,
                    observationCount: 1,
                    contextDigests: [contextDigest]
                )
            }
        }
    }

    /// Returns the most specific ready opening in the current draft. This is a
    /// read-only lookup; it neither learns from nor changes the current draft.
    public func suggestion(forCurrentDraft draft: String) -> SessionPatternSuggestion? {
        lock.lock()
        let observedGeneration = generation
        lock.unlock()

        let candidates = Self.extractCandidates(from: draft)
        guard !candidates.isEmpty else { return nil }

        lock.lock()
        defer { lock.unlock() }
        guard generation == observedGeneration else { return nil }

        let matches: [(ExtractedCandidate, CandidateRecord)] = candidates.compactMap { candidate in
            let key = digest(domain: "candidate", value: candidate.normalizedPhrase)
            guard let record = records[key], record.isReady else { return nil }
            return (candidate, record)
        }
        guard let best = matches.max(by: { lhs, rhs in
            if lhs.1.tokenCount != rhs.1.tokenCount {
                return lhs.1.tokenCount < rhs.1.tokenCount
            }
            return lhs.1.displayPhrase.count < rhs.1.displayPhrase.count
        }) else { return nil }

        return SessionPatternSuggestion(
            displayPhrase: best.1.displayPhrase,
            exactDeleteText: best.0.exactDeleteText,
            range: best.0.range,
            observationCount: best.1.observationCount,
            distinctContextCount: best.1.contextDigests.count
        )
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        records.removeAll(keepingCapacity: false)
        observedDraftCount = 0
        eligibleDraftCount = 0
        duplicateContextObservationCount = 0
        salt = Self.makeSalt()
        generation = UUID()
    }

    public var summary: SessionPatternSummary {
        lock.lock()
        defer { lock.unlock() }
        return SessionPatternSummary(
            observedDraftCount: observedDraftCount,
            eligibleDraftCount: eligibleDraftCount,
            retainedCandidateCount: records.count,
            readyCandidateCount: records.values.lazy.filter(\.isReady).count,
            distinctContextCount: records.values.reduce(0) {
                Self.saturatingAdd($0, $1.contextDigests.count)
            },
            duplicateContextObservationCount: duplicateContextObservationCount
        )
    }

    /// A privacy-focused serialization used by tests. It mirrors every retained
    /// text-bearing field, and deliberately has no draft or suffix field.
    func _privacySnapshotDataForTesting() -> Data {
        lock.lock()
        defer { lock.unlock() }
        let candidates: [[String: Any]] = records.values.map { record in
            [
                "displayPhrase": record.displayPhrase,
                "kind": record.kind.rawValue,
                "tokenCount": record.tokenCount,
                "observationCount": record.observationCount,
                "contextDigests": record.contextDigests.sorted(),
            ]
        }
        let object: [String: Any] = [
            "observedDraftCount": observedDraftCount,
            "eligibleDraftCount": eligibleDraftCount,
            "duplicateContextObservationCount": duplicateContextObservationCount,
            "candidates": candidates,
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    private func digest(domain: String, value: String) -> String {
        var data = Data(domain.utf8)
        data.append(0)
        data.append(salt)
        data.append(0)
        data.append(Data(value.utf8))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func extractCandidates(from draft: String) -> [ExtractedCandidate] {
        guard !draft.isEmpty else { return [] }
        let lineEnd = draft.firstIndex(where: { $0 == "\n" || $0 == "\r" }) ?? draft.endIndex
        guard draft.startIndex < lineEnd else { return [] }

        var contentStart = draft.startIndex
        var leadingSpaceCount = 0
        while contentStart < lineEnd,
              draft[contentStart] == " " {
            leadingSpaceCount += 1
            contentStart = draft.index(after: contentStart)
        }
        guard contentStart < lineEnd else { return [] }
        if leadingSpaceCount >= 4 || draft[contentStart] == "\t" { return [] }

        let content = draft[contentStart..<lineEnd]
        guard !isExcludedStart(content) else { return [] }

        if let commaCandidate = commaCandidate(
            in: draft,
            contentStart: contentStart,
            lineEnd: lineEnd
        ) {
            return [commaCandidate]
        }
        return plainCandidates(
            in: draft,
            contentStart: contentStart,
            lineEnd: lineEnd
        )
    }

    private static func commaCandidate(
        in draft: String,
        contentStart: String.Index,
        lineEnd: String.Index
    ) -> ExtractedCandidate? {
        var cursor = contentStart
        var characterCount = 0
        var commaIndex: String.Index?
        while cursor < lineEnd, characterCount < maximumDisplayCharacters {
            let character = draft[cursor]
            characterCount += 1
            if character == "," || character == "，" {
                commaIndex = cursor
                break
            }
            cursor = draft.index(after: cursor)
        }
        guard let commaIndex else { return nil }

        let beforeComma = draft[contentStart..<commaIndex]
        let tokens = tokenSpans(in: draft, range: contentStart..<commaIndex)
        guard (1...3).contains(tokens.count), containsSubstantiveCharacter(beforeComma) else {
            return nil
        }

        let displayEnd = draft.index(after: commaIndex)
        let displayPhrase = String(draft[contentStart..<displayEnd])
        guard isDisplayPhraseWithinLimits(displayPhrase) else { return nil }

        let deleteEnd = horizontalWhitespaceEnd(in: draft, from: displayEnd, limit: lineEnd)
        let context = normalizeContext(String(draft[deleteEnd..<draft.endIndex]))
        guard !context.isEmpty else { return nil }

        return makeCandidate(
            draft: draft,
            displayPhrase: displayPhrase,
            kind: .comma,
            tokenCount: tokens.count,
            deleteStart: draft.startIndex,
            deleteEnd: deleteEnd,
            normalizedContext: context
        )
    }

    private static func plainCandidates(
        in draft: String,
        contentStart: String.Index,
        lineEnd: String.Index
    ) -> [ExtractedCandidate] {
        let tokens = tokenSpans(in: draft, range: contentStart..<lineEnd)
        guard tokens.count >= 2 else { return [] }

        var result: [ExtractedCandidate] = []
        for count in 1...min(3, tokens.count - 1) {
            let end = tokens[count - 1].end
            let phraseSlice = draft[contentStart..<end]
            guard phraseSlice.count <= maximumDisplayCharacters else { break }
            guard containsSubstantiveCharacter(phraseSlice) else { continue }
            let displayPhrase = String(phraseSlice)
            guard isDisplayPhraseWithinLimits(displayPhrase) else { break }

            let deleteEnd = horizontalWhitespaceEnd(in: draft, from: end, limit: lineEnd)
            let context = normalizeContext(String(draft[deleteEnd..<draft.endIndex]))
            guard !context.isEmpty else { continue }
            result.append(makeCandidate(
                draft: draft,
                displayPhrase: displayPhrase,
                kind: .plain,
                tokenCount: count,
                deleteStart: draft.startIndex,
                deleteEnd: deleteEnd,
                normalizedContext: context
            ))
        }
        return result
    }

    private static func makeCandidate(
        draft: String,
        displayPhrase: String,
        kind: CandidateKind,
        tokenCount: Int,
        deleteStart: String.Index,
        deleteEnd: String.Index,
        normalizedContext: String
    ) -> ExtractedCandidate {
        let deleteRange = deleteStart..<deleteEnd
        let nsRange = NSRange(deleteRange, in: draft)
        return ExtractedCandidate(
            displayPhrase: displayPhrase,
            normalizedPhrase: normalizePhrase(displayPhrase),
            kind: kind,
            tokenCount: tokenCount,
            exactDeleteText: String(draft[deleteRange]),
            range: SessionPatternTextRange(location: nsRange.location, length: nsRange.length),
            normalizedContext: normalizedContext
        )
    }

    private static func tokenSpans(
        in value: String,
        range: Range<String.Index>
    ) -> [TokenSpan] {
        var spans: [TokenSpan] = []
        var cursor = range.lowerBound
        while cursor < range.upperBound {
            while cursor < range.upperBound, value[cursor].isWhitespace {
                cursor = value.index(after: cursor)
            }
            guard cursor < range.upperBound else { break }
            let start = cursor
            while cursor < range.upperBound, !value[cursor].isWhitespace {
                cursor = value.index(after: cursor)
            }
            spans.append(TokenSpan(start: start, end: cursor))
        }
        return spans
    }

    private static func horizontalWhitespaceEnd(
        in value: String,
        from start: String.Index,
        limit: String.Index
    ) -> String.Index {
        var cursor = start
        while cursor < limit {
            let character = value[cursor]
            guard character == " " || character == "\t" else { break }
            cursor = value.index(after: cursor)
        }
        return cursor
    }

    private static func containsSubstantiveCharacter(_ value: Substring) -> Bool {
        value.unicodeScalars.contains { scalar in
            scalar.properties.isAlphabetic
                || scalar.properties.numericType != nil
                || scalar.properties.isEmoji
        }
    }

    private static func isDisplayPhraseWithinLimits(_ phrase: String) -> Bool {
        phrase.count <= maximumDisplayCharacters
            && phrase.utf16.count <= maximumDisplayUTF16Units
            && phrase.utf8.count <= maximumDisplayUTF8Bytes
    }

    private static func normalizePhrase(_ phrase: String) -> String {
        collapseWhitespace(
            phrase.precomposedStringWithCompatibilityMapping.folding(
                options: [.caseInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
        )
    }

    private static func normalizeContext(_ context: String) -> String {
        collapseWhitespace(
            context.precomposedStringWithCompatibilityMapping.folding(
                options: [.caseInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
        )
    }

    private static func collapseWhitespace(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func isExcludedStart(_ content: Substring) -> Bool {
        let lowercased = content.lowercased()
        if lowercased.hasPrefix("http://")
            || lowercased.hasPrefix("https://")
            || lowercased.hasPrefix("www.") {
            return true
        }

        if content.hasPrefix("```")
            || content.hasPrefix("~~~")
            || content.hasPrefix("`") {
            return true
        }

        let quotePrefixes = [">", "\"", "'", "“", "‘", "「", "『", "《"]
        if quotePrefixes.contains(where: content.hasPrefix) { return true }

        if content.hasPrefix("/") || content.hasPrefix("!") { return true }
        for prompt in ["$", "%", "#"] {
            if content == Substring(prompt)
                || content.hasPrefix(prompt + " ")
                || content.hasPrefix(prompt + "\t") {
                return true
            }
        }

        for bullet in ["-", "*", "+", "•", "‣", "◦"] {
            if content.hasPrefix(bullet + " ") || content.hasPrefix(bullet + "\t") {
                return true
            }
        }
        for bullet in ["–", "—"] {
            if content.hasPrefix(bullet + " ") || content.hasPrefix(bullet + "\t") {
                return true
            }
        }
        if content.hasPrefix("[ ] ")
            || content.hasPrefix("[x] ")
            || content.hasPrefix("[X] ") {
            return true
        }

        var headingCursor = content.startIndex
        while headingCursor < content.endIndex, content[headingCursor] == "#" {
            headingCursor = content.index(after: headingCursor)
        }
        if headingCursor > content.startIndex,
           headingCursor < content.endIndex,
           content[headingCursor].isWhitespace {
            return true
        }

        let components = content.split(whereSeparator: \.isWhitespace)
        if components.count >= 2,
           components[0].contains("@"),
           (components[1] == "$" || components[1] == "%" || components[1] == "#") {
            return true
        }

        // These are structural source-code markers rather than learned words.
        // False positives are intentionally resolved in favor of not learning.
        for marker in [" = ", " := ", " => ", " -> ", "&&", "||", "{", "}", ";"] {
            if content.contains(marker) { return true }
        }

        var cursor = content.startIndex
        while cursor < content.endIndex, content[cursor].isNumber {
            cursor = content.index(after: cursor)
        }
        if cursor > content.startIndex, cursor < content.endIndex,
           (content[cursor] == "." || content[cursor] == ")") {
            let afterMarker = content.index(after: cursor)
            if afterMarker == content.endIndex || content[afterMarker].isWhitespace {
                return true
            }
        }
        return false
    }

    private static func makeSalt() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    private static func saturatingIncrement(_ value: Int) -> Int {
        value == .max ? value : value + 1
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : result
    }
}
