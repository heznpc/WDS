import Foundation

/// Centralized `UserDefaults` keys for everything WDS persists.
enum Preferences {
    static let enabled = "wds.enabled"
    static let allowedBundleIdentifiers = "wds.allowedBundleIdentifiers"
    static let autoWatchBundleIdentifiers = "wds.autoWatchBundleIdentifiers.v1"
    static let tokenSavingsLedger = "wds.tokenSavingsLedger.v1"
    static let tokenSavingsLedgerCorruptBackup = "wds.tokenSavingsLedger.v1.corruptBackup"
    static let phraseDictionary = "wds.phraseDictionary.v1"
    static let phraseDictionaryCorruptBackup = "wds.phraseDictionary.v1.corruptBackup"
}
