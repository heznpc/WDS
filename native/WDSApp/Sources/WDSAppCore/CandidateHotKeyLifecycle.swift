import Foundation

/// Pairs the candidate review panel with its two global hot keys.
///
/// The panel and the hot keys must appear and disappear together. A live
/// registration without a visible panel would let `⌃⌘⌫` delete a span the user
/// can no longer see, which is the one failure this type exists to make
/// impossible to reach silently.
///
/// Registration can legitimately fail — another app may already own the
/// combination — and the panel is still shown in that case, just without the
/// shortcut hints. That is why "shown" and "registered" are separate facts
/// rather than one flag.
public struct CandidateHotKeyLifecycle: Equatable, Sendable {
    private var shown: CurrentDraftCandidateIdentity?
    private var registered: CurrentDraftCandidateIdentity?

    public init() {}

    /// Whether the review panel is currently on screen.
    public var isShowing: Bool { shown != nil }

    /// The candidate the panel is currently offering, if any.
    public var shownIdentity: CurrentDraftCandidateIdentity? { shown }

    /// Whether the panel should advertise `⌃⌘K` / `⌃⌘⌫`.
    public var keyboardShortcutsAvailable: Bool {
        registered != nil && registered == shown
    }

    /// True when hot keys are registered for something the user cannot see.
    ///
    /// Always false in any correct sequence. Tests assert this over the whole
    /// state space so a future edit cannot introduce the condition unnoticed.
    public var hasOrphanedRegistration: Bool {
        guard let registered else { return false }
        return registered != shown
    }

    /// Records that the panel became visible for `identity`.
    ///
    /// `hotKeysRegistered` is the result the hot-key controller reported, not a
    /// request: passing `false` records a panel shown without shortcuts.
    public mutating func didShow(
        _ identity: CurrentDraftCandidateIdentity,
        hotKeysRegistered: Bool
    ) {
        shown = identity
        registered = hotKeysRegistered ? identity : nil
    }

    /// Records that both the hot keys and the panel were released.
    ///
    /// Safe to call when nothing is shown, which lets the app funnel every
    /// dismissal path through one unconditional call.
    public mutating func didHide() {
        shown = nil
        registered = nil
    }

    /// Whether a hot-key callback for `identity` is still about the live panel.
    ///
    /// A Carbon event can be delivered after the panel was replaced. The
    /// one-shot `CandidateCommandGate` already refuses a stale registration;
    /// this additionally refuses an event whose candidate is no longer the one
    /// on screen.
    public func acceptsCommand(
        for identity: CurrentDraftCandidateIdentity
    ) -> Bool {
        shown == identity
    }
}
