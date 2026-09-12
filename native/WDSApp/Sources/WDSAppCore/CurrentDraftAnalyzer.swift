import Foundation
import Inertbox

/// An exact UTF-16 range suitable for macOS Accessibility APIs.
public struct CurrentDraftUTF16Range: Equatable, Sendable {
    public let location: Int
    public let length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

/// Why a span was considered removable from this draft.
public enum CurrentDraftDeletionReason: String, Equatable, Sendable {
    /// An emotional interjection that is either detachable from a usable
    /// prompt or occupies the entire draft by itself. This class is lexical
    /// and local; it is not a general profanity filter.
    case detachableEmotionalInterjection
    /// A narrow Korean intensifier used before an independently meaningful
    /// negative evaluation. Requirement-bearing uses (for example, asking for
    /// something to be extremely large) are deliberately excluded.
    case removableEmotionalIntensifier
    /// A comma-delimited conversational opener whose removal leaves a
    /// substantial sentence behind.
    case detachableConversationalOpening
    /// The same known hesitation marker was immediately repeated with its own
    /// punctuation; only the first copy is proposed for removal.
    case duplicateHesitation
    /// A prose comma was immediately duplicated; all but the first comma are
    /// proposed for removal.
    case duplicatePunctuation
    /// A Korean particle was spelled against the 받침 of the syllable in front
    /// of it, in one of the directions that cannot also be an ordinary word.
    case correctedParticle
    /// A spelling from a closed table whose observed form has no valid reading,
    /// so the corrected form cannot change what the draft means.
    case correctedSpelling
}

/// Whether a candidate is suitable for ordinary review or has especially
/// strong local evidence. Neither value authorizes automatic deletion.
public enum CurrentDraftDeletionSafety: String, Equatable, Sendable {
    case reviewRequired
    case high
}

/// A local-only proposal to edit an exact span of the current draft.
///
/// `originalText` includes any whitespace that should leave with the span and
/// is guaranteed to match `range` in the analyzed draft.
public struct CurrentDraftDeletionCandidate: Equatable, Sendable {
    public let range: CurrentDraftUTF16Range
    public let originalText: String
    /// What the span becomes. Empty means the span is removed outright, which
    /// is every candidate WDS produced before corrections existed.
    public let replacementText: String
    public let reason: CurrentDraftDeletionReason
    public let confidence: Double
    public let safety: CurrentDraftDeletionSafety

    public init(
        range: CurrentDraftUTF16Range,
        originalText: String,
        replacementText: String = "",
        reason: CurrentDraftDeletionReason,
        confidence: Double,
        safety: CurrentDraftDeletionSafety
    ) {
        self.range = range
        self.originalText = originalText
        self.replacementText = replacementText
        self.reason = reason
        self.confidence = confidence
        self.safety = safety
    }

    /// Whether applying this candidate substitutes text instead of removing it.
    public var isCorrection: Bool { !replacementText.isEmpty }

    /// How much leaving this span in place is expected to distort the model's
    /// reading of the request, from 0 to 1.
    ///
    /// This is a second axis rather than a refinement of `confidence`, because
    /// the two measure opposite things and rank candidates in opposite orders.
    /// `confidence` asks how sure we are that editing the span is harmless; a
    /// duplicated comma scores highest there and matters least. This axis asks
    /// what it costs to send the draft unedited, where an opening profanity —
    /// which can draw a refusal or a tone-managing reply instead of an answer —
    /// scores highest.
    ///
    /// The values are per-reason constants. Anything finer would require
    /// judging the sentence, which is the remote call this product does not make.
    public var interpretiveImpact: Double {
        switch reason {
        case .detachableEmotionalInterjection:
            return 0.95
        case .removableEmotionalIntensifier:
            // Reads as a magnitude requirement rather than as emphasis.
            return 0.80
        case .correctedParticle:
            // A wrong particle can swap which noun is the subject and which is
            // the object, so the request itself can be misread.
            return 0.55
        case .correctedSpelling:
            return 0.30
        case .duplicateHesitation:
            return 0.20
        case .detachableConversationalOpening:
            return 0.15
        case .duplicatePunctuation:
            return 0.05
        }
    }
}

/// Conservatively proposes a few deletion spans from one current draft.
///
/// The analyzer has no learning, persistence, networking, or cross-call text
/// state. It deliberately returns no candidate when local syntax does not make
/// a removal sufficiently clear. A candidate is always an offer for explicit
/// user review, never permission to edit or submit text automatically.
public struct CurrentDraftAnalyzer: Sendable {
    private static let hardCandidateLimit = 3
    private static let maximumDraftUTF16Length = 32_768
    private static let minimumRemainderSubstantiveScalars = 6

    /// These are discourse or hesitation markers, not words learned from the
    /// user. A comma boundary is still required before any is considered.
    private static let detachableOpenings = DraftDisfluencyLexicon.detachableOpenings

    /// Repetition is only meaningful for this narrower lexical class. Repeated
    /// arbitrary words are never treated as deletion evidence.
    private static let hesitationMarkers = DraftDisfluencyLexicon.hesitationMarkers

    /// Explicit forms only. Similar-looking words are not inferred, stemmed,
    /// or learned from the user.
    private static let detachedEmotionalMarkers =
        DraftDisfluencyLexicon.detachableEmotionalMarkers

    /// Forms that carry reference and so are only removable when they are the
    /// entire draft. Lifting one out of a sentence would take the object or the
    /// predicate with it.
    private static let standaloneEmotionalMarkers =
        DraftDisfluencyLexicon.standaloneEmotionalMarkers

    /// `존나` can carry a real magnitude requirement ("존나 크게"). It is
    /// only considered before this narrow set of already-negative predicates,
    /// where deleting the intensifier leaves the evaluation intact.
    private static let removableIntensifiers =
        DraftDisfluencyLexicon.removableIntensifiers
    private static let independentlyNegativePredicatePrefixes =
        DraftDisfluencyLexicon.independentlyNegativePredicatePrefixes

    private let maximumCandidates: Int
    private let includesCorrections: Bool

    /// - Parameter includesCorrections: Whether to also propose substitutions
    ///   (particle agreement and closed-table spellings) rather than deletions
    ///   only. Off by default: a substitution needs a write path that can put
    ///   text back, and a caller that can only delete would otherwise strip the
    ///   misspelled token instead of fixing it.
    public init(maximumCandidates: Int = 3, includesCorrections: Bool = false) {
        self.maximumCandidates = min(
            max(maximumCandidates, 0),
            Self.hardCandidateLimit
        )
        self.includesCorrections = includesCorrections
    }

    public func analyze(_ draft: String) -> [CurrentDraftDeletionCandidate] {
        guard draft.utf16.count <= Self.maximumDraftUTF16Length else { return [] }
        guard let protected = try? Inertbox.protectedRanges(in: draft) else { return [] }
        guard !protected.isEmpty else { return analyzeUserText(draft) }
        let source = draft as NSString
        var cursor = 0
        var candidates: [CurrentDraftDeletionCandidate] = []
        // Analyze each user-authored span independently. Joining both sides of a
        // quote could invent a sentence, and would invalidate the edit offsets.
        for boundary in protected + [NSRange(location: source.length, length: 0)] {
            if boundary.location > cursor {
                let span = source.substring(with: NSRange(location: cursor, length: boundary.location - cursor))
                candidates += analyzeUserText(span).map { candidate in
                    CurrentDraftDeletionCandidate(
                        range: CurrentDraftUTF16Range(location: cursor + candidate.range.location, length: candidate.range.length),
                        originalText: candidate.originalText,
                        replacementText: candidate.replacementText,
                        reason: candidate.reason,
                        confidence: candidate.confidence,
                        safety: candidate.safety
                    )
                }
            }
            cursor = NSMaxRange(boundary)
        }
        return Array(candidates.prefix(maximumCandidates))
    }

    private func analyzeUserText(_ draft: String) -> [CurrentDraftDeletionCandidate] {
        guard maximumCandidates > 0,
              !draft.isEmpty,
              draft.utf16.count <= Self.maximumDraftUTF16Length,
              !Self.isExcludedDraft(draft)
        else { return [] }

        var candidates: [CurrentDraftDeletionCandidate] = []

        if let emotionalNoise = Self.emotionalNoiseCandidate(in: draft) {
            // Offer one emotional span at a time. Re-analyzing the edited
            // draft can expose the next one without presenting a pile of
            // censorship-like replacements at once.
            candidates.append(emotionalNoise)
        }

        if let duplicateHesitation = Self.duplicateHesitationCandidate(in: draft) {
            candidates.append(duplicateHesitation)
        } else if let opening = Self.detachableOpeningCandidate(in: draft) {
            candidates.append(opening)
        }

        candidates.append(contentsOf: Self.duplicatePunctuationCandidates(in: draft))

        if includesCorrections {
            candidates.append(contentsOf: Self.correctionCandidates(in: draft))
        }

        let ranked = candidates.sorted { lhs, rhs in
            if lhs.confidence != rhs.confidence {
                return lhs.confidence > rhs.confidence
            }
            if lhs.safety != rhs.safety {
                return lhs.safety == .high
            }
            if lhs.range.location != rhs.range.location {
                return lhs.range.location < rhs.range.location
            }
            return lhs.range.length > rhs.range.length
        }

        var result: [CurrentDraftDeletionCandidate] = []
        for candidate in ranked where result.count < maximumCandidates {
            guard !result.contains(where: { Self.overlaps($0.range, candidate.range) }) else {
                continue
            }
            result.append(candidate)
        }
        return result
    }

    private struct LeadingHesitationUnit {
        let normalizedPhrase: String
        let deleteEnd: String.Index
    }

    private static func emotionalNoiseCandidate(
        in draft: String
    ) -> CurrentDraftDeletionCandidate? {
        guard !hasMetalinguisticEmotionalContext(draft) else { return nil }

        if let standalone = standaloneEmotionalDraftCandidate(in: draft) {
            return standalone
        }

        var candidates: [CurrentDraftDeletionCandidate] = []
        if let suffix = detachedEmotionalSuffixCandidate(in: draft) {
            candidates.append(suffix)
        }
        if let prefix = detachedEmotionalPrefixCandidate(in: draft) {
            candidates.append(prefix)
        }
        candidates.append(contentsOf: detachedEmotionalInteriorCandidates(in: draft))
        candidates.append(contentsOf: emotionalIntensifierCandidates(in: draft))

        return candidates.sorted { lhs, rhs in
            if lhs.confidence != rhs.confidence {
                return lhs.confidence > rhs.confidence
            }
            if lhs.safety != rhs.safety {
                return lhs.safety == .high
            }
            return lhs.range.location < rhs.range.location
        }.first
    }

    private static func standaloneEmotionalDraftCandidate(
        in draft: String
    ) -> CurrentDraftDeletionCandidate? {
        var contentStart = draft.startIndex
        while contentStart < draft.endIndex, isHorizontalWhitespace(draft[contentStart]) {
            contentStart = draft.index(after: contentStart)
        }

        var contentEnd = draft.endIndex
        while contentEnd > contentStart {
            let previous = draft.index(before: contentEnd)
            guard isHorizontalWhitespace(draft[previous]) else { break }
            contentEnd = previous
        }
        guard contentStart < contentEnd else { return nil }

        var markerEnd = contentEnd
        while markerEnd > contentStart {
            let previous = draft.index(before: markerEnd)
            guard isInterjectionPunctuation(draft[previous]) else { break }
            markerEnd = previous
        }
        // Compared raw, not normalized. Compatibility folding rewrites the
        // Hangul compatibility jamo in `ㅅㅂ` into conjoining jamo, which would
        // stop it matching its own lexicon entry.
        //
        // A draft that is nothing but an expletive has no request left to
        // protect, so the referential forms are admissible here and only here.
        let marker = String(draft[contentStart..<markerEnd])
        guard markerEnd > contentStart,
              detachedEmotionalMarkers.contains(marker)
                  || standaloneEmotionalMarkers.contains(marker)
        else { return nil }

        return makeCandidate(
            in: draft,
            range: draft.startIndex..<draft.endIndex,
            reason: .detachableEmotionalInterjection,
            confidence: 0.99,
            safety: .reviewRequired
        )
    }

    private static func detachedEmotionalPrefixCandidate(
        in draft: String
    ) -> CurrentDraftDeletionCandidate? {
        guard draft.first?.isWhitespace != true,
              let marker = exactTokenRanges(
                of: detachedEmotionalMarkers,
                in: draft
              ).first(where: { $0.lowerBound == draft.startIndex })
        else { return nil }

        var cursor = marker.upperBound
        var wasPunctuated = false
        while cursor < draft.endIndex, isInterjectionPunctuation(draft[cursor]) {
            wasPunctuated = true
            cursor = draft.index(after: cursor)
        }

        let whitespaceStart = cursor
        cursor = horizontalWhitespaceEnd(
            in: draft,
            from: cursor,
            limit: draft.endIndex
        )
        guard cursor > whitespaceStart else { return nil }

        let deletionRange = draft.startIndex..<cursor
        guard removalLeavesUsablePrompt(deletionRange, in: draft) else { return nil }

        return makeCandidate(
            in: draft,
            range: deletionRange,
            reason: .detachableEmotionalInterjection,
            confidence: wasPunctuated ? 0.965 : 0.94,
            safety: wasPunctuated ? .high : .reviewRequired
        )
    }

    private static func detachedEmotionalSuffixCandidate(
        in draft: String
    ) -> CurrentDraftDeletionCandidate? {
        var contentEnd = draft.endIndex
        while contentEnd > draft.startIndex {
            let previous = draft.index(before: contentEnd)
            guard isHorizontalWhitespace(draft[previous]) else { break }
            contentEnd = previous
        }
        guard contentEnd > draft.startIndex else { return nil }

        var markerEnd = contentEnd
        while markerEnd > draft.startIndex {
            let previous = draft.index(before: markerEnd)
            guard isSentenceTerminal(draft[previous]) else { break }
            markerEnd = previous
        }

        guard let marker = exactTokenRanges(
            of: detachedEmotionalMarkers,
            in: draft
        ).first(where: { $0.upperBound == markerEnd }) else { return nil }

        var gapStart = marker.lowerBound
        while gapStart > draft.startIndex {
            let previous = draft.index(before: gapStart)
            guard isHorizontalWhitespace(draft[previous]) else { break }
            gapStart = previous
        }
        guard gapStart < marker.lowerBound else { return nil }

        var deletionStart = gapStart
        var leftEnd = gapStart
        if leftEnd > draft.startIndex {
            let previous = draft.index(before: leftEnd)
            if isComma(draft[previous]) {
                deletionStart = previous
                leftEnd = previous
            }
        }

        let punctuationAfterMarker = markerEnd < contentEnd
        var deletionEnd = marker.upperBound
        if punctuationAfterMarker, leftEnd > draft.startIndex {
            let previous = draft.index(before: leftEnd)
            if isSentenceTerminal(draft[previous]) {
                // `고쳐 줘. 시발.` should become `고쳐 줘.`, not
                // `고쳐 줘..`.
                deletionEnd = contentEnd
            }
        }

        let deletionRange = deletionStart..<deletionEnd
        guard isUsablePromptFragment(draft[draft.startIndex..<leftEnd]),
              removalLeavesUsablePrompt(deletionRange, in: draft)
        else { return nil }

        return makeCandidate(
            in: draft,
            range: deletionRange,
            reason: .detachableEmotionalInterjection,
            confidence: 0.975,
            safety: .high
        )
    }

    private static func detachedEmotionalInteriorCandidates(
        in draft: String
    ) -> [CurrentDraftDeletionCandidate] {
        let interiorMarkers = DraftDisfluencyLexicon.interiorEmotionalMarkers
        var candidates: [CurrentDraftDeletionCandidate] = []

        for marker in exactTokenRanges(of: interiorMarkers, in: draft) {
            guard marker.lowerBound > draft.startIndex,
                  marker.upperBound < draft.endIndex
            else { continue }

            let beforeMarker = draft.index(before: marker.lowerBound)
            guard isHorizontalWhitespace(draft[beforeMarker]) else { continue }

            var cursor = marker.upperBound
            var wasCommaDelimited = false
            if cursor < draft.endIndex, isComma(draft[cursor]) {
                wasCommaDelimited = true
                cursor = draft.index(after: cursor)
                // A punctuation repair and an emotional deletion should not
                // be fused into one proposal.
                guard cursor == draft.endIndex || !isComma(draft[cursor]) else {
                    continue
                }
            }

            let whitespaceStart = cursor
            cursor = horizontalWhitespaceEnd(
                in: draft,
                from: cursor,
                limit: draft.endIndex
            )
            guard cursor > whitespaceStart,
                  substantiveScalarCount(in: draft[draft.startIndex..<marker.lowerBound]) >= 2,
                  substantiveScalarCount(in: draft[cursor..<draft.endIndex]) >= 3
            else { continue }

            let deletionRange = marker.lowerBound..<cursor
            guard removalLeavesUsablePrompt(deletionRange, in: draft) else { continue }

            candidates.append(makeCandidate(
                in: draft,
                range: deletionRange,
                reason: .detachableEmotionalInterjection,
                confidence: wasCommaDelimited ? 0.945 : 0.90,
                safety: wasCommaDelimited ? .high : .reviewRequired
            ))
        }
        return candidates
    }

    private static func emotionalIntensifierCandidates(
        in draft: String
    ) -> [CurrentDraftDeletionCandidate] {
        var candidates: [CurrentDraftDeletionCandidate] = []

        for marker in exactTokenRanges(of: removableIntensifiers, in: draft) {
            if marker.lowerBound > draft.startIndex {
                let previous = draft.index(before: marker.lowerBound)
                guard isHorizontalWhitespace(draft[previous]) else { continue }
            }

            let whitespaceStart = marker.upperBound
            let remainderStart = horizontalWhitespaceEnd(
                in: draft,
                from: whitespaceStart,
                limit: draft.endIndex
            )
            guard remainderStart > whitespaceStart,
                  remainderStart < draft.endIndex
            else { continue }

            let nextUnit = draft[remainderStart...].prefix { character in
                !character.isWhitespace && !character.isPunctuation
            }
            let normalizedNextUnit = normalizePhrase(String(nextUnit))
            guard independentlyNegativePredicatePrefixes.contains(where: {
                normalizedNextUnit.hasPrefix($0)
            }) else { continue }

            let deletionRange = marker.lowerBound..<remainderStart
            guard removalLeavesUsablePrompt(deletionRange, in: draft) else { continue }

            candidates.append(makeCandidate(
                in: draft,
                range: deletionRange,
                reason: .removableEmotionalIntensifier,
                confidence: 0.885,
                safety: .reviewRequired
            ))
        }
        return candidates
    }

    private static func exactTokenRanges(
        of markers: [String],
        in draft: String
    ) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var cursor = draft.startIndex

        while cursor < draft.endIndex {
            for marker in markers {
                guard draft[cursor...].hasPrefix(marker) else { continue }
                let markerEnd = draft.index(cursor, offsetBy: marker.count)

                if cursor > draft.startIndex {
                    let previous = draft.index(before: cursor)
                    guard !isWordConstituent(draft[previous]) else { continue }
                }
                if markerEnd < draft.endIndex {
                    guard !isWordConstituent(draft[markerEnd]) else { continue }
                }

                ranges.append(cursor..<markerEnd)
                break
            }
            cursor = draft.index(after: cursor)
        }
        return ranges
    }

    private static func removalLeavesUsablePrompt(
        _ range: Range<String.Index>,
        in draft: String
    ) -> Bool {
        let remainder = String(draft[..<range.lowerBound])
            + String(draft[range.upperBound...])
        return isUsablePromptFragment(remainder[...])
    }

    private static func isUsablePromptFragment(_ value: Substring) -> Bool {
        let trimmed = value.drop(while: \Character.isWhitespace)
        guard !trimmed.isEmpty,
              let first = trimmed.first,
              !isComma(first),
              substantiveScalarCount(in: trimmed) >= 3
        else { return false }

        return trimmed.contains(where: isSubstantive)
    }

    private static func hasMetalinguisticEmotionalContext(_ draft: String) -> Bool {
        let normalized = normalizePhrase(draft)
        let explicitCues = [
            "욕설", "비속어", "금칙어", "단어", "표현", "문구", "문자열",
            "텍스트", "인용", "번역", "검열", "필터링", "치환", "탐지",
            "감지", "뜻을", "뜻이", "의미를", "의미가",
            // The English side of the lexicon needs the same escape hatch, or a
            // draft that is *about* a slur has the slur taken out from under it.
            "profanity", "swear", "curse word", "slur", "the word",
            "translate", "verbatim", "censor", "moderation", "blocklist",
            "denylist", "word list", "regex",
        ]
        if explicitCues.contains(where: normalized.contains) { return true }

        let mentionSuffixes = [
            "이라는", "이란", "이라고 쓰", "을 제거", "를 제거", "을 삭제",
            "를 삭제", "을 지워", "를 지워", "그대로 출력", "그대로 보내",
            "그대로 전송", "그대로 써", "그대로 적어", "그대로 유지",
            "그대로 보존", "그대로 말해", "그대로 읽어", "그대로 복사해",
            "원문 그대로",
        ]
        let mentionComparable = normalizePhrase(String(normalized.map { character in
            isInterjectionPunctuation(character) ? " " : character
        }))
        let normalizedSuffixes = mentionSuffixes.map(normalizePhrase)

        // The guard has to span the whole vocabulary, not a hand-picked subset,
        // or an expanded lexicon quietly turns `fuck을 지워줘` into a draft whose
        // own subject gets deleted. Testing presence before the suffix loop keeps
        // that from costing one full scan per form on every debounce.
        for form in DraftDisfluencyLexicon.mentionableEmotionalForms {
            let normalizedForm = normalizePhrase(form)
            guard mentionComparable.contains(normalizedForm) else { continue }
            for suffix in normalizedSuffixes {
                if mentionComparable.contains(normalizedForm + suffix)
                    || mentionComparable.contains(normalizedForm + " " + suffix) {
                    return true
                }
            }
        }
        return false
    }

    private static func detachableOpeningCandidate(
        in draft: String
    ) -> CurrentDraftDeletionCandidate? {
        guard draft.first?.isWhitespace != true else { return nil }
        let lineEnd = firstLineEnd(in: draft, from: draft.startIndex)
        guard let comma = draft[draft.startIndex..<lineEnd].firstIndex(where: isComma) else {
            return nil
        }

        let phrase = String(draft[draft.startIndex..<comma])
        let normalizedPhrase = normalizePhrase(phrase)
        guard detachableOpenings.contains(normalizedPhrase) else { return nil }

        let afterComma = draft.index(after: comma)
        // A run such as `아니,,` is handled as punctuation first. Treating the
        // opener as detachable before repairing it would be an ambiguous jump.
        guard afterComma == lineEnd || !isComma(draft[afterComma]) else { return nil }
        let deleteEnd = horizontalWhitespaceEnd(in: draft, from: afterComma, limit: lineEnd)
        let remainder = draft[deleteEnd..<lineEnd]
        guard isMeaningfulRemainder(remainder),
              !remainderEchoesOpening(remainder, normalizedOpening: normalizedPhrase)
        else { return nil }

        return makeCandidate(
            in: draft,
            range: draft.startIndex..<deleteEnd,
            reason: .detachableConversationalOpening,
            confidence: 0.86,
            safety: .reviewRequired
        )
    }

    private static func duplicateHesitationCandidate(
        in draft: String
    ) -> CurrentDraftDeletionCandidate? {
        guard draft.first?.isWhitespace != true,
              let first = leadingHesitationUnit(in: draft, from: draft.startIndex),
              let second = leadingHesitationUnit(in: draft, from: first.deleteEnd),
              first.normalizedPhrase == second.normalizedPhrase
        else { return nil }

        let lineEnd = firstLineEnd(in: draft, from: second.deleteEnd)
        let remainder = draft[second.deleteEnd..<lineEnd]
        guard isMeaningfulRemainder(remainder) else { return nil }

        return makeCandidate(
            in: draft,
            range: draft.startIndex..<first.deleteEnd,
            reason: .duplicateHesitation,
            confidence: 0.99,
            safety: .high
        )
    }

    private static func leadingHesitationUnit(
        in draft: String,
        from start: String.Index
    ) -> LeadingHesitationUnit? {
        let lineEnd = firstLineEnd(in: draft, from: start)
        guard start < lineEnd else { return nil }

        var cursor = start
        var punctuationStart: String.Index?
        while cursor < lineEnd {
            let character = draft[cursor]
            if isComma(character) || character == "." || character == "…" {
                punctuationStart = cursor
                break
            }
            guard character.isLetter || character.isWhitespace else { return nil }
            cursor = draft.index(after: cursor)
        }
        guard let punctuationStart,
              punctuationStart > start
        else { return nil }

        let rawPhrase = draft[start..<punctuationStart]
        guard rawPhrase.last?.isWhitespace != true else { return nil }
        let normalizedPhrase = normalizePhrase(String(rawPhrase))
        guard hesitationMarkers.contains(normalizedPhrase) else { return nil }

        cursor = punctuationStart
        if isComma(draft[cursor]) {
            cursor = draft.index(after: cursor)
            // Consecutive commas are a punctuation candidate, not a hesitation
            // boundary.
            guard cursor == lineEnd || !isComma(draft[cursor]) else { return nil }
        } else if draft[cursor] == "…" {
            repeat {
                cursor = draft.index(after: cursor)
            } while cursor < lineEnd && draft[cursor] == "…"
        } else {
            var dotCount = 0
            while cursor < lineEnd, draft[cursor] == "." {
                dotCount += 1
                cursor = draft.index(after: cursor)
            }
            guard dotCount >= 2 else { return nil }
        }

        let whitespaceStart = cursor
        cursor = horizontalWhitespaceEnd(in: draft, from: cursor, limit: lineEnd)
        // The visible gap is part of the repeated unit and prevents matching
        // identifiers, CSV, or unfinished punctuation runs.
        guard cursor > whitespaceStart, cursor < lineEnd else { return nil }
        return LeadingHesitationUnit(
            normalizedPhrase: normalizedPhrase,
            deleteEnd: cursor
        )
    }

    private static func duplicatePunctuationCandidates(
        in draft: String
    ) -> [CurrentDraftDeletionCandidate] {
        var result: [CurrentDraftDeletionCandidate] = []
        var cursor = draft.startIndex

        while cursor < draft.endIndex {
            guard isComma(draft[cursor]) else {
                cursor = draft.index(after: cursor)
                continue
            }

            let runStart = cursor
            repeat {
                cursor = draft.index(after: cursor)
            } while cursor < draft.endIndex && isComma(draft[cursor])
            let firstEnd = draft.index(after: runStart)
            guard firstEnd < cursor,
                  isProseCommaRun(in: draft, runStart: runStart, runEnd: cursor)
            else { continue }

            result.append(makeCandidate(
                in: draft,
                range: firstEnd..<cursor,
                reason: .duplicatePunctuation,
                confidence: 0.98,
                safety: .high
            ))
        }
        return result
    }

    private static func isProseCommaRun(
        in draft: String,
        runStart: String.Index,
        runEnd: String.Index
    ) -> Bool {
        guard runStart > draft.startIndex,
              runEnd < draft.endIndex,
              isHorizontalWhitespace(draft[runEnd])
        else { return false }

        let previous = draft.index(before: runStart)
        guard isSubstantive(draft[previous]), !draft[previous].isNumber else { return false }

        let lineStart = draft[..<runStart].lastIndex(where: { $0 == "\n" || $0 == "\r" })
            .map { draft.index(after: $0) } ?? draft.startIndex
        let leftContext = draft[lineStart..<runStart]
        guard substantiveScalarCount(in: leftContext) >= 2 else { return false }

        let lineEnd = firstLineEnd(in: draft, from: runEnd)
        let remainderStart = horizontalWhitespaceEnd(in: draft, from: runEnd, limit: lineEnd)
        return isMeaningfulRemainder(draft[remainderStart..<lineEnd])
    }

    private static func isMeaningfulRemainder(_ remainder: Substring) -> Bool {
        let trimmed = remainder.drop(while: \Character.isWhitespace)
        guard !trimmed.isEmpty,
              let first = trimmed.first,
              isSubstantive(first),
              substantiveScalarCount(in: trimmed) >= minimumRemainderSubstantiveScalars
        else { return false }

        let lexicalUnits = trimmed.split { character in
            character.isWhitespace || character.isPunctuation
        }
        return lexicalUnits.count >= 2
            || substantiveScalarCount(in: trimmed) >= 9
    }

    private static func remainderEchoesOpening(
        _ remainder: Substring,
        normalizedOpening: String
    ) -> Bool {
        let firstUnit = remainder.prefix { character in
            !character.isWhitespace && !character.isPunctuation
        }
        let normalizedFirstUnit = normalizePhrase(String(firstUnit))
        guard !normalizedFirstUnit.isEmpty else { return true }
        if normalizedFirstUnit == normalizedOpening { return true }

        // `아니라고`, `아니면`, and similar forms carry negation or an
        // alternative rather than merely echoing a detachable opener.
        if normalizedOpening == "아니", normalizedFirstUnit.hasPrefix("아니") {
            return true
        }
        return false
    }

    private static func makeCandidate(
        in draft: String,
        range: Range<String.Index>,
        replacement: String = "",
        reason: CurrentDraftDeletionReason,
        confidence: Double,
        safety: CurrentDraftDeletionSafety
    ) -> CurrentDraftDeletionCandidate {
        let nsRange = NSRange(range, in: draft)
        return CurrentDraftDeletionCandidate(
            range: CurrentDraftUTF16Range(
                location: nsRange.location,
                length: nsRange.length
            ),
            originalText: String(draft[range]),
            replacementText: replacement,
            reason: reason,
            confidence: confidence,
            safety: safety
        )
    }

    // MARK: - Corrections

    /// Substitution proposals: particle agreement first, then closed-table
    /// spellings.
    ///
    /// Corrections are reported as one candidate per token and never overlap a
    /// deletion, because the ranking pass drops any candidate that intersects an
    /// already-accepted range. A token that both misspells a particle and
    /// misspells its stem yields the particle repair now and the spelling repair
    /// on the next analysis of the edited draft, which is the same
    /// one-offer-at-a-time behaviour the deletion rules use.
    private static func correctionCandidates(
        in draft: String
    ) -> [CurrentDraftDeletionCandidate] {
        // A draft that is talking *about* wording should not have its wording
        // silently rewritten. The same cues that protect a quoted expletive —
        // 단어, 표현, 문자열, 치환 — also mark a draft whose spelling is the
        // subject rather than a mistake.
        guard !hasMetalinguisticEmotionalContext(draft) else { return [] }

        var result: [CurrentDraftDeletionCandidate] = []
        var repaired = Set<Int>()

        for repair in ParticleAgreement.repairs(in: draft) {
            guard let candidate = correctionCandidate(
                in: draft,
                repair: repair,
                reason: .correctedParticle,
                confidence: 0.93,
                // Particle agreement leans on a blocklist of ordinary words, so
                // it is a strong heuristic rather than a closed set.
                safety: .reviewRequired
            ) else { continue }
            repaired.insert(candidate.range.location)
            result.append(candidate)
        }

        for repair in OrthographyRepair.repairs(in: draft) {
            guard let candidate = correctionCandidate(
                in: draft,
                repair: repair,
                reason: .correctedSpelling,
                confidence: 0.95,
                // The observed form has no valid reading at all, which is the
                // strongest local evidence any rule in this file has.
                safety: .high
            ), !repaired.contains(candidate.range.location) else { continue }
            result.append(candidate)
        }
        return result
    }

    private static func correctionCandidate(
        in draft: String,
        repair: DraftSpanRepair,
        reason: CurrentDraftDeletionReason,
        confidence: Double,
        safety: CurrentDraftDeletionSafety
    ) -> CurrentDraftDeletionCandidate? {
        // An empty span, an empty replacement, or a replacement identical to the
        // span all mean the rule misfired. The middle case matters most: an
        // empty replacement would travel down the pipeline as a deletion and
        // remove the token the user was trying to fix.
        guard !repair.range.isEmpty,
              !repair.replacement.isEmpty,
              String(draft[repair.range]) != repair.replacement
        else { return nil }

        return makeCandidate(
            in: draft,
            range: repair.range,
            replacement: repair.replacement,
            reason: reason,
            confidence: confidence,
            safety: safety
        )
    }

    private static func overlaps(
        _ lhs: CurrentDraftUTF16Range,
        _ rhs: CurrentDraftUTF16Range
    ) -> Bool {
        lhs.location < rhs.location + rhs.length
            && rhs.location < lhs.location + lhs.length
    }

    private static func firstLineEnd(
        in value: String,
        from start: String.Index
    ) -> String.Index {
        value[start...].firstIndex(where: { $0 == "\n" || $0 == "\r" })
            ?? value.endIndex
    }

    private static func horizontalWhitespaceEnd(
        in value: String,
        from start: String.Index,
        limit: String.Index
    ) -> String.Index {
        var cursor = start
        while cursor < limit, isHorizontalWhitespace(value[cursor]) {
            cursor = value.index(after: cursor)
        }
        return cursor
    }

    private static func isHorizontalWhitespace(_ character: Character) -> Bool {
        character == " " || character == "\t"
    }

    private static func isComma(_ character: Character) -> Bool {
        character == "," || character == "，"
    }

    private static func isSentenceTerminal(_ character: Character) -> Bool {
        character == "." || character == "!" || character == "?"
            || character == "…" || character == "。" || character == "！"
            || character == "？"
    }

    private static func isInterjectionPunctuation(_ character: Character) -> Bool {
        isComma(character) || isSentenceTerminal(character)
    }

    private static func isWordConstituent(_ character: Character) -> Bool {
        isSubstantive(character) || character == "_"
    }

    private static func isSubstantive(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            scalar.properties.isAlphabetic || scalar.properties.numericType != nil
        }
    }

    private static func substantiveScalarCount(in value: Substring) -> Int {
        value.unicodeScalars.lazy.filter { scalar in
            scalar.properties.isAlphabetic || scalar.properties.numericType != nil
        }.count
    }

    private static func normalizePhrase(_ phrase: String) -> String {
        phrase.precomposedStringWithCompatibilityMapping.folding(
            options: [.caseInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .split(whereSeparator: \Character.isWhitespace)
        .joined(separator: " ")
    }

    private static func isExcludedDraft(_ draft: String) -> Bool {
        if draft.contains("\0") || draft.contains("`") { return true }

        let normalized = draft.precomposedStringWithCompatibilityMapping.folding(
            options: [.caseInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        if normalized.range(
            of: #"(?:https?://|www\.)"#,
            options: .regularExpression
        ) != nil {
            return true
        }

        // These markers strongly suggest source code, shell syntax, or a data
        // structure. False negatives are preferable to altering those inputs.
        for marker in [" = ", " := ", " => ", " -> ", "&&", "||", "{", "}"] {
            if draft.contains(marker) { return true }
        }

        // Paired or typographic quote marks make speaker boundaries ambiguous.
        for quote in ["\"", "“", "”", "‘", "’", "「", "」", "『", "』", "《", "》"] {
            if draft.contains(quote) { return true }
        }

        return draft.split(
            omittingEmptySubsequences: false,
            whereSeparator: { $0 == "\n" || $0 == "\r" }
        ).contains(where: isExcludedLine)
    }

    private static func isExcludedLine(_ rawLine: Substring) -> Bool {
        var cursor = rawLine.startIndex
        var leadingSpaces = 0
        while cursor < rawLine.endIndex, rawLine[cursor] == " " {
            leadingSpaces += 1
            cursor = rawLine.index(after: cursor)
        }
        if leadingSpaces >= 4 || (cursor < rawLine.endIndex && rawLine[cursor] == "\t") {
            return true
        }

        let line = rawLine[cursor...]
        guard !line.isEmpty else { return false }

        for prefix in [">", "\"", "'", "“", "‘", "「", "『", "《"] {
            if line.hasPrefix(prefix) { return true }
        }
        if line.hasPrefix("/") || line.hasPrefix("!") { return true }

        for prompt in ["$", "%", "#"] {
            if line == Substring(prompt)
                || line.hasPrefix(prompt + " ")
                || line.hasPrefix(prompt + "\t") {
                return true
            }
        }

        for bullet in ["-", "*", "+", "•", "‣", "◦", "–", "—"] {
            if line.hasPrefix(bullet + " ") || line.hasPrefix(bullet + "\t") {
                return true
            }
        }
        if line.hasPrefix("[ ] ")
            || line.hasPrefix("[x] ")
            || line.hasPrefix("[X] ") {
            return true
        }

        var numberEnd = line.startIndex
        while numberEnd < line.endIndex, line[numberEnd].isNumber {
            numberEnd = line.index(after: numberEnd)
        }
        if numberEnd > line.startIndex,
           numberEnd < line.endIndex,
           line[numberEnd] == "." || line[numberEnd] == ")" {
            let afterMarker = line.index(after: numberEnd)
            if afterMarker == line.endIndex || line[afterMarker].isWhitespace {
                return true
            }
        }
        return false
    }
}
