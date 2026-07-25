import Foundation

/// Why a dictionary entry could not be created.
public enum DictionaryEntryError: Error, Equatable, Sendable {
    /// The phrase was empty after trimming (and after dropping a trailing comma).
    case emptyPhrase
    /// The replacement is identical to the phrase, so applying it would be a
    /// no-op edit that saves nothing.
    case noOpReplacement
    /// The replacement contains the phrase, so applying it would re-create a
    /// match at the same spot and an automatic apply would edit forever.
    case recursiveReplacement
}

/// One user-registered habitual phrase.
///
/// This is the durable, user-authored counterpart to the app's built-in
/// `CurrentDraftAnalyzer`: the analyzer guesses at emotional filler with fixed
/// local rules, whereas a `DictionaryEntry` is an explicit phrase the user
/// chose to trim from their own drafts. An entry either deletes the phrase
/// (`replacement` empty) or folds a verbose habit into a short standard form
/// (`replacement` non-empty), e.g. "봐주실 수 있을까요" → "봐줘".
///
/// Because the phrase text is authored by the user (not extracted from a draft),
/// persisting it does not conflict with the app's never-store-draft promise.
public struct DictionaryEntry: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    /// The canonical phrase to match: trimmed, with any trailing comma removed
    /// into `requireComma`. Mirrors `createRule` in the web prototype.
    public let phrase: String
    /// Replacement text, or "" for a pure deletion.
    public let replacement: String
    /// When true the phrase only matches when immediately followed by a comma,
    /// and the comma is removed with it.
    public let requireComma: Bool
    /// Whether the entry participates in matching.
    public var isActive: Bool
    /// When true the entry is applied without the review panel, iPhone
    /// text-replacement style. The same delete/replace safety preconditions
    /// still run; only the user confirmation step is skipped.
    public var autoApply: Bool

    /// True when applying the entry substitutes text rather than deleting it.
    public var isReplacement: Bool { !replacement.isEmpty }

    /// Normalizes and validates a user-entered phrase the way the web
    /// prototype's `createRule` does: trims whitespace, lifts a trailing comma
    /// into `requireComma`, and rejects an empty, no-op, or self-recreating
    /// entry.
    public init(
        id: String,
        rawPhrase: String,
        replacement: String = "",
        isActive: Bool = true,
        autoApply: Bool = false
    ) throws {
        let trimmed = rawPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let requireComma = trimmed.hasSuffix(",") || trimmed.hasSuffix("，")
        var canonical = trimmed
        if requireComma {
            canonical = String(canonical.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !canonical.isEmpty else { throw DictionaryEntryError.emptyPhrase }

        let cleanedReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanedReplacement != canonical else { throw DictionaryEntryError.noOpReplacement }
        guard !cleanedReplacement.contains(canonical) else {
            throw DictionaryEntryError.recursiveReplacement
        }

        self.id = id
        self.phrase = canonical
        self.replacement = cleanedReplacement
        self.requireComma = requireComma
        self.isActive = isActive
        self.autoApply = autoApply
    }

    private enum CodingKeys: String, CodingKey {
        case id, phrase, replacement, requireComma, isActive, autoApply
    }

    /// Custom decoding so dictionaries persisted before `autoApply` existed
    /// keep loading instead of tripping the corrupt-blob fallback.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        phrase = try container.decode(String.self, forKey: .phrase)
        replacement = try container.decode(String.self, forKey: .replacement)
        requireComma = try container.decode(Bool.self, forKey: .requireComma)
        isActive = try container.decode(Bool.self, forKey: .isActive)
        autoApply = try container.decodeIfPresent(Bool.self, forKey: .autoApply) ?? false
    }
}

/// The user's collection of habitual phrases, persisted as a whole.
public struct PhraseDictionary: Codable, Equatable, Sendable {
    public private(set) var entries: [DictionaryEntry]

    public init(entries: [DictionaryEntry] = []) {
        self.entries = entries
    }

    /// Entries eligible for matching, in registration order.
    public var activeEntries: [DictionaryEntry] {
        entries.filter { $0.isActive }
    }

    /// Adds `entry` unless an entry with the same phrase and comma requirement
    /// already exists. Returns whether it was added.
    @discardableResult
    public mutating func add(_ entry: DictionaryEntry) -> Bool {
        let duplicate = entries.contains {
            $0.phrase == entry.phrase && $0.requireComma == entry.requireComma
        }
        guard !duplicate else { return false }
        entries.append(entry)
        return true
    }

    /// Removes the entry with `id`, if present.
    public mutating func remove(id: String) {
        entries.removeAll { $0.id == id }
    }

    /// Enables or disables the entry with `id`, if present.
    public mutating func setActive(_ active: Bool, id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].isActive = active
    }

    /// Turns automatic apply on or off for the entry with `id`, if present.
    public mutating func setAutoApply(_ autoApply: Bool, id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].autoApply = autoApply
    }
}
