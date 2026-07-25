import Foundation
import WDSAppCore

/// Owns the token-savings ledger and its `UserDefaults` persistence, turning a
/// confirmed edit into a recorded, estimated saving. Keeps the app delegate free
/// of the estimator, clock, and persistence detail.
///
/// An undecodable persisted blob is preserved under a backup key rather than
/// overwritten, so a transient corruption never silently destroys the lifetime
/// total.
final class SavingsStore {
    private let defaults: UserDefaults
    private var ledger: SavingsLedger

    init(defaults: UserDefaults) {
        self.defaults = defaults
        ledger = Self.load(from: defaults)
    }

    /// Estimated tokens saved during the current ISO week.
    var weeklyTokens: Int { ledger.tokens(inPeriod: SavingsPeriod.weekKey(for: Date())) }

    /// Estimated tokens saved over the ledger's lifetime.
    var lifetimeTokens: Int { ledger.lifetimeTokens }

    /// Records one confirmed edit: `removed` is the exact text taken out of the
    /// draft, `replacement` is what replaced it ("" for a pure deletion). The
    /// saving is the net estimated token difference. Returns that estimate so the
    /// caller can show immediate feedback. Call on the main thread.
    @discardableResult
    func record(removed: String, replacement: String = "") -> Int {
        let saved = max(0, TokenEstimator.estimate(removed) - TokenEstimator.estimate(replacement))
        ledger.record(savedTokens: saved, periodKey: SavingsPeriod.weekKey(for: Date()))
        persist()
        return saved
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        defaults.set(data, forKey: Preferences.tokenSavingsLedger)
    }

    private static func load(from defaults: UserDefaults) -> SavingsLedger {
        guard let data = defaults.data(forKey: Preferences.tokenSavingsLedger) else {
            return SavingsLedger()
        }
        if let ledger = try? JSONDecoder().decode(SavingsLedger.self, from: data) {
            return ledger
        }
        // Keep the FIRST corrupt blob (closest to the last good state) and log,
        // mirroring PhraseDictionaryStore.
        if defaults.data(forKey: Preferences.tokenSavingsLedgerCorruptBackup) == nil {
            defaults.set(data, forKey: Preferences.tokenSavingsLedgerCorruptBackup)
        }
        NSLog("WDS: savings ledger failed to decode; starting empty (backup kept under %@)",
              Preferences.tokenSavingsLedgerCorruptBackup)
        return SavingsLedger()
    }
}
