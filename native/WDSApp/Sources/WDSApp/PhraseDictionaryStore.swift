import Foundation
import WDSAppCore

/// Owns the user's phrase dictionary and its `UserDefaults` persistence, exposing
/// the CRUD the menu drives and persisting after every mutation.
///
/// Because these phrases are the user's own authored content, an undecodable
/// persisted blob is preserved under a backup key rather than overwritten.
final class PhraseDictionaryStore {
    private let defaults: UserDefaults
    private(set) var dictionary: PhraseDictionary

    init(defaults: UserDefaults) {
        self.defaults = defaults
        dictionary = Self.load(from: defaults)
    }

    var entries: [DictionaryEntry] { dictionary.entries }

    /// Adds `entry`, persisting on success. Returns whether it was added (false
    /// if a duplicate already exists).
    @discardableResult
    func add(_ entry: DictionaryEntry) -> Bool {
        let added = dictionary.add(entry)
        if added { persist() }
        return added
    }

    func remove(id: String) {
        dictionary.remove(id: id)
        persist()
    }

    /// Flips the active flag of the entry with `id`, if present.
    func toggleActive(id: String) {
        guard let entry = dictionary.entries.first(where: { $0.id == id }) else { return }
        dictionary.setActive(!entry.isActive, id: id)
        persist()
    }

    /// Flips the automatic-apply flag of the entry with `id`, if present.
    func toggleAutoApply(id: String) {
        guard let entry = dictionary.entries.first(where: { $0.id == id }) else { return }
        dictionary.setAutoApply(!entry.autoApply, id: id)
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(dictionary) else { return }
        defaults.set(data, forKey: Preferences.phraseDictionary)
    }

    private static func load(from defaults: UserDefaults) -> PhraseDictionary {
        guard let data = defaults.data(forKey: Preferences.phraseDictionary) else {
            return PhraseDictionary()
        }
        if let dictionary = try? JSONDecoder().decode(PhraseDictionary.self, from: data) {
            return dictionary
        }
        // Keep the FIRST corrupt blob (closest to the last good state) rather
        // than letting a later corruption overwrite it, and leave a trace so
        // the silent reset is at least discoverable in the log.
        if defaults.data(forKey: Preferences.phraseDictionaryCorruptBackup) == nil {
            defaults.set(data, forKey: Preferences.phraseDictionaryCorruptBackup)
        }
        NSLog("WDS: phrase dictionary failed to decode; starting empty (backup kept under %@)",
              Preferences.phraseDictionaryCorruptBackup)
        return PhraseDictionary()
    }
}
