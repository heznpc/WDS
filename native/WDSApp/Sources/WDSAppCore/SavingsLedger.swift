import Foundation

/// Computes the period bucket a savings event belongs to.
///
/// The ledger itself is period-agnostic: it stores one "current period" and a
/// lifetime total, and rolls the period over whenever it sees a new key. This
/// helper produces the key the app passes in — an ISO-8601 week so that "이번
/// 주" (this week) matches the user's calendar week and rolls over on Monday.
public enum SavingsPeriod {
    /// A stable, ordered key for the ISO-8601 week containing `date`.
    ///
    /// Encoded as `yearForWeekOfYear * 100 + weekOfYear` so that comparing two
    /// keys for inequality is a correct "different week" test and larger means
    /// later. Uses `yearForWeekOfYear` (not the calendar year) so the turn of
    /// the year does not split or merge a single ISO week. Because a week number
    /// never reaches 100 the encoding is injective and monotonic across the
    /// 52/53→1 year boundary (2020-W53 = 202053 < 2021-W01 = 202101).
    ///
    /// The default calendar deliberately inherits the device's local time zone:
    /// "이번 주" (this week) should track the user's own calendar week and roll
    /// over at their local Monday, not at UTC midnight. This is single-user,
    /// device-local state that is never compared across devices, so local-zone
    /// bucketing is the intended behaviour. A caller that needs a fixed zone
    /// (e.g. a deterministic test) can inject its own calendar.
    public static func weekKey(for date: Date, calendar: Calendar = Calendar(identifier: .iso8601)) -> Int {
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        let year = components.yearForWeekOfYear ?? 0
        let week = components.weekOfYear ?? 0
        return year * 100 + week
    }
}

/// A running tally of the tokens WDS has helped remove from drafts.
///
/// The ledger is a pure value type with no clock, no I/O, and no persistence of
/// its own: the app supplies the period key (see `SavingsPeriod`) and persists
/// the encoded ledger through `UserDefaults`. It keeps only O(1) state — a
/// lifetime total plus the current period's total — so persistence never grows.
///
/// "Saved tokens" is always `estimate(removed) - estimate(replacement)` clamped
/// to a non-negative value. For a plain deletion the replacement is empty, so a
/// saving equals the estimated cost of the removed span; the same shape extends
/// to future replace-style dictionary entries without changing this type.
public struct SavingsLedger: Codable, Equatable, Sendable {
    /// Total estimated tokens saved over the ledger's whole lifetime.
    public private(set) var lifetimeTokens: Int
    /// Total number of phrases removed over the ledger's whole lifetime.
    public private(set) var lifetimePhrases: Int
    /// The key of the period the current-period counters belong to. Zero means
    /// no event has been recorded yet.
    public private(set) var periodKey: Int
    /// Estimated tokens saved during the current period.
    public private(set) var periodTokens: Int
    /// Phrases removed during the current period.
    public private(set) var periodPhrases: Int

    public init(
        lifetimeTokens: Int = 0,
        lifetimePhrases: Int = 0,
        periodKey: Int = 0,
        periodTokens: Int = 0,
        periodPhrases: Int = 0
    ) {
        self.lifetimeTokens = lifetimeTokens
        self.lifetimePhrases = lifetimePhrases
        self.periodKey = periodKey
        self.periodTokens = periodTokens
        self.periodPhrases = periodPhrases
    }

    /// Records one confirmed removal of `savedTokens` estimated tokens within
    /// the period identified by `periodKey`.
    ///
    /// The lifetime totals are always exact: every recorded removal adds to them
    /// unconditionally. The current-period counters track exactly one period —
    /// the most recently recorded key — so this is a single-bucket "current
    /// week only" model, not a full history. If `periodKey` differs from the
    /// stored period the current-period counters roll over to zero before this
    /// event is added. A consequence: if the clock moves backward across a week
    /// boundary (a time-zone change or manual clock adjustment) and an older key
    /// recurs, the current-period counter restarts for that week rather than
    /// resuming its earlier subtotal. That only affects the cosmetic weekly
    /// figure, never the lifetime totals. Negative `savedTokens` are clamped to
    /// zero (a replacement that grew the text saved nothing) but the phrase is
    /// still counted, because a removal did happen.
    public mutating func record(savedTokens: Int, periodKey: Int) {
        if periodKey != self.periodKey {
            self.periodKey = periodKey
            periodTokens = 0
            periodPhrases = 0
        }

        let saved = max(0, savedTokens)
        lifetimeTokens += saved
        lifetimePhrases += 1
        periodTokens += saved
        periodPhrases += 1
    }

    /// The tokens saved in `periodKey`, or zero if that is not the current
    /// period. Lets a reader ask "how much this week?" without first rolling the
    /// period over via a write.
    public func tokens(inPeriod periodKey: Int) -> Int {
        periodKey == self.periodKey ? periodTokens : 0
    }
}
