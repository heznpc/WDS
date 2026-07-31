import Foundation

/// One observed draft, scoped to the exact process and focus that produced it.
///
/// The scope fields are part of the value on purpose: a draft read from one
/// process must never be compared against, or edited in, another.
public struct CurrentDraftSnapshot: Equatable, Sendable {
    public let bundleIdentifier: String
    public let processIdentifier: Int32
    public let focusEpoch: Int
    public let text: String

    public init(
        bundleIdentifier: String,
        processIdentifier: Int32,
        focusEpoch: Int,
        text: String
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.focusEpoch = focusEpoch
        self.text = text
    }
}

/// Everything that must be unchanged for a candidate to still be the same offer.
///
/// Equality is the re-verification contract. If any field differs the candidate
/// is a different one, and a decision the user made about the old candidate
/// must not carry over.
public struct CurrentDraftCandidateIdentity: Equatable, Sendable {
    public let bundleIdentifier: String
    public let processIdentifier: Int32
    public let focusEpoch: Int
    public let range: CurrentDraftUTF16Range
    public let originalText: String

    public init(
        bundleIdentifier: String,
        processIdentifier: Int32,
        focusEpoch: Int,
        range: CurrentDraftUTF16Range,
        originalText: String
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.focusEpoch = focusEpoch
        self.range = range
        self.originalText = originalText
    }
}

/// A candidate plus the exact draft scope it was derived from.
public struct CurrentDraftCandidateState: Equatable, Sendable {
    public let identity: CurrentDraftCandidateIdentity
    public let candidate: CurrentDraftDeletionCandidate

    public init(
        identity: CurrentDraftCandidateIdentity,
        candidate: CurrentDraftDeletionCandidate
    ) {
        self.identity = identity
        self.candidate = candidate
    }

    /// The phrase shown in the review panel and the menu.
    public var displayPhrase: String {
        candidate.originalText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Permission for one debounced inspection to proceed.
///
/// Each scheduling attempt takes a fresh generation. A timer that fires after a
/// newer keystroke rescheduled the work holds a stale generation and is refused,
/// which is what keeps a delayed callback from acting on a replaced candidate.
public struct CandidateInspectionTicket: Equatable, Sendable {
    public let identity: CurrentDraftCandidateIdentity
    fileprivate let generation: UInt64

    fileprivate init(identity: CurrentDraftCandidateIdentity, generation: UInt64) {
        self.identity = identity
        self.generation = generation
    }
}

/// What the coordinator should do after folding in a new draft snapshot.
public enum CurrentDraftCandidateOutcome: Equatable, Sendable {
    /// No usable candidate. Release the panel and any pending inspection.
    case cleared
    /// The same candidate is still current and the panel is already hidden.
    case unchanged
    /// The user kept typing while the panel was up, so hide it. It stays
    /// available from the menu until the candidate itself changes.
    case hiddenWhileTyping(CurrentDraftCandidateState)
    /// The user already chose 유지 for this exact candidate in this field.
    case alreadyKept(CurrentDraftCandidateState)
    /// A new candidate was adopted and an inspection may be scheduled.
    case readyToInspect(CurrentDraftCandidateState)
}

/// Why an approved candidate was not deleted.
public enum CandidateApprovalDecision: Equatable, Sendable {
    /// The draft still yields the exact same candidate; deletion may proceed.
    case proceed(CurrentDraftCandidateState)
    /// The draft, focus, or candidate changed. Keep the text.
    case stale
}

/// Tracks the lifetime of the single current-draft deletion candidate.
///
/// This owns the three things that decide whether an asynchronous callback is
/// still allowed to act: which candidate is current, which candidates the user
/// already answered, and which debounced inspection is the newest. It performs
/// no I/O and holds no reference to AppKit, so every refusal path is directly
/// testable. Facts that only the app can know — whether the engine is on,
/// whether the panel is up, whether the target app is still frontmost — are
/// passed in by the caller rather than sampled here.
public struct CurrentDraftCandidateTracker: Equatable, Sendable {
    /// Quiet period after a keystroke before the candidate is inspected.
    public static let typingDebounce: TimeInterval = 0.4
    /// Shorter delay used when re-offering a candidate after another operation.
    public static let resumeDebounce: TimeInterval = 0.2

    public private(set) var state: CurrentDraftCandidateState?
    private var keptIdentity: CurrentDraftCandidateIdentity?
    private var typingDismissedIdentity: CurrentDraftCandidateIdentity?
    private var generation: UInt64 = 0
    private var pendingGeneration: UInt64?

    public init() {}

    // MARK: - Derivation

    /// Derives a candidate for one draft and re-checks it against that draft.
    ///
    /// The analyzer already reports an exact range, but the range is re-read out
    /// of the snapshot here so that a candidate can never carry a range that
    /// does not literally spell `originalText` in the text it will be applied to.
    public static func candidateState(
        for snapshot: CurrentDraftSnapshot,
        analyzer: CurrentDraftAnalyzer
    ) -> CurrentDraftCandidateState? {
        guard let candidate = analyzer.analyze(snapshot.text).first else { return nil }
        let source = snapshot.text as NSString
        let location = candidate.range.location
        let length = candidate.range.length
        guard location >= 0,
              length > 0,
              length <= source.length,
              location <= source.length - length,
              source.substring(with: NSRange(location: location, length: length))
                  == candidate.originalText
        else { return nil }

        return CurrentDraftCandidateState(
            identity: CurrentDraftCandidateIdentity(
                bundleIdentifier: snapshot.bundleIdentifier,
                processIdentifier: snapshot.processIdentifier,
                focusEpoch: snapshot.focusEpoch,
                range: candidate.range,
                originalText: candidate.originalText
            ),
            candidate: candidate
        )
    }

    // MARK: - Queries

    public var hasPendingInspection: Bool { pendingGeneration != nil }

    public func isKept(_ identity: CurrentDraftCandidateIdentity) -> Bool {
        keptIdentity == identity
    }

    public func isHiddenWhileTyping(_ identity: CurrentDraftCandidateIdentity) -> Bool {
        typingDismissedIdentity == identity
    }

    /// Whether this candidate may still be offered to the user at all.
    public func isActionable(_ identity: CurrentDraftCandidateIdentity) -> Bool {
        keptIdentity != identity && typingDismissedIdentity != identity
    }

    // MARK: - Draft updates

    /// Folds a fresh draft snapshot into the tracker and reports what to do.
    ///
    /// Pass `nil` when the draft is gone: focus moved, the field went secure,
    /// the sensor stopped, or the text no longer yields a candidate.
    public mutating func refresh(
        with snapshot: CurrentDraftSnapshot?,
        analyzer: CurrentDraftAnalyzer,
        isPanelVisible: Bool
    ) -> CurrentDraftCandidateOutcome {
        guard let snapshot,
              let next = Self.candidateState(for: snapshot, analyzer: analyzer)
        else {
            pendingGeneration = nil
            state = nil
            return .cleared
        }

        if state?.identity == next.identity {
            // Same offer. Refresh the payload but never re-prompt, and treat a
            // visible panel plus continued typing as the user ignoring it.
            state = next
            guard isPanelVisible else { return .unchanged }
            typingDismissedIdentity = next.identity
            return .hiddenWhileTyping(next)
        }

        pendingGeneration = nil
        state = next
        // A different candidate is a different question, so the "kept typing"
        // dismissal of the previous one does not apply to it.
        typingDismissedIdentity = nil
        if keptIdentity == next.identity {
            return .alreadyKept(next)
        }
        return .readyToInspect(next)
    }

    /// Drops the candidate and every decision recorded about it.
    ///
    /// Used at draft lifetime boundaries: focus change, watch stop, engine off,
    /// secure field, sensor rejection, app termination.
    public mutating func reset() {
        pendingGeneration = nil
        state = nil
        keptIdentity = nil
        typingDismissedIdentity = nil
    }

    // MARK: - Debounced inspection

    /// Takes a ticket for a new debounced inspection, invalidating any older one.
    ///
    /// Returns `nil` when the candidate must not be offered right now, in which
    /// case no timer should be armed.
    public mutating func scheduleInspection(
        for identity: CurrentDraftCandidateIdentity,
        engineEnabled: Bool,
        isIdle: Bool
    ) -> CandidateInspectionTicket? {
        guard engineEnabled, isIdle, isActionable(identity) else { return nil }
        generation &+= 1
        pendingGeneration = generation
        return CandidateInspectionTicket(identity: identity, generation: generation)
    }

    /// Re-offers the current candidate after an unrelated operation finished.
    public mutating func resumeInspection(
        isPanelVisible: Bool,
        engineEnabled: Bool,
        isIdle: Bool
    ) -> CandidateInspectionTicket? {
        guard let state,
              isActionable(state.identity),
              !isPanelVisible,
              isIdle
        else { return nil }
        return scheduleInspection(
            for: state.identity,
            engineEnabled: engineEnabled,
            isIdle: isIdle
        )
    }

    /// Shows a candidate the user hid by continuing to type.
    ///
    /// Clears only the typing dismissal. A candidate the user explicitly kept
    /// stays suppressed for this field.
    public mutating func reshowInspection(
        engineEnabled: Bool,
        isIdle: Bool
    ) -> CandidateInspectionTicket? {
        guard let state, keptIdentity != state.identity else { return nil }
        typingDismissedIdentity = nil
        return scheduleInspection(
            for: state.identity,
            engineEnabled: engineEnabled,
            isIdle: isIdle
        )
    }

    /// Whether a fired timer still holds the newest ticket for a live candidate.
    public func canBeginInspection(_ ticket: CandidateInspectionTicket) -> Bool {
        pendingGeneration == ticket.generation
            && state?.identity == ticket.identity
            && isActionable(ticket.identity)
    }

    /// Consumes the pending ticket immediately before launching the inspection.
    @discardableResult
    public mutating func beginInspection(
        _ ticket: CandidateInspectionTicket
    ) -> Bool {
        guard canBeginInspection(ticket) else { return false }
        pendingGeneration = nil
        return true
    }

    /// Abandons any armed inspection without touching the candidate itself.
    public mutating func cancelPendingInspection() {
        pendingGeneration = nil
    }

    // MARK: - Re-verification

    /// Whether an inspection result may still be shown to the user.
    ///
    /// The draft is re-derived so that text which changed while the helper
    /// process was running cannot produce a panel pointing at a stale range.
    public func canPresent(
        _ ticket: CandidateInspectionTicket,
        latestSnapshot: CurrentDraftSnapshot?,
        analyzer: CurrentDraftAnalyzer
    ) -> Bool {
        guard state?.identity == ticket.identity,
              isActionable(ticket.identity),
              let latestSnapshot,
              Self.candidateState(for: latestSnapshot, analyzer: analyzer)?.identity
                  == ticket.identity
        else { return false }
        return true
    }

    /// Whether the live draft still yields this exact candidate.
    ///
    /// This is the re-derivation on its own, without the engine or idle gate, so
    /// it can also be used partway through a delete that already owns the
    /// interaction and is therefore no longer idle.
    public func stillMatches(
        _ identity: CurrentDraftCandidateIdentity,
        latestSnapshot: CurrentDraftSnapshot?,
        analyzer: CurrentDraftAnalyzer
    ) -> CurrentDraftCandidateState? {
        guard let latestSnapshot,
              let latest = Self.candidateState(for: latestSnapshot, analyzer: analyzer),
              latest.identity == identity
        else { return nil }
        return latest
    }

    /// Final gate before deleting. Re-derives the candidate from the live draft.
    ///
    /// A `proceed` here still only authorizes the app to ask the bridge to
    /// delete, and the bridge re-checks the draft digest, process, and range
    /// once more before writing.
    public func approval(
        of identity: CurrentDraftCandidateIdentity,
        latestSnapshot: CurrentDraftSnapshot?,
        analyzer: CurrentDraftAnalyzer,
        engineEnabled: Bool,
        isIdle: Bool
    ) -> CandidateApprovalDecision {
        guard engineEnabled,
              isIdle,
              let latest = stillMatches(
                  identity,
                  latestSnapshot: latestSnapshot,
                  analyzer: analyzer
              )
        else { return .stale }
        return .proceed(latest)
    }

    // MARK: - User decisions

    /// Records 유지 for this exact candidate in this field.
    ///
    /// This is a session-scoped silence, not learning: nothing is persisted and
    /// the suppression dies with the draft scope.
    @discardableResult
    public mutating func keep(
        _ identity: CurrentDraftCandidateIdentity
    ) -> Bool {
        guard state?.identity == identity else { return false }
        keptIdentity = identity
        pendingGeneration = nil
        return true
    }
}
