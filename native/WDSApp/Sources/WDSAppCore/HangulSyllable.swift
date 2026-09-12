import Foundation

/// Arithmetic over precomposed Hangul syllables.
///
/// Korean particle allomorphy is decided by whether the syllable in front of a
/// particle carries a final consonant (받침). That question is answered by
/// integer arithmetic on the Unicode scalar, so the analyzer can settle it
/// locally without a dictionary, a morphological analyzer, or a third-party
/// package.
public enum HangulSyllable {
    private static let syllableBase: UInt32 = 0xAC00
    private static let syllableEnd: UInt32 = 0xD7A3
    private static let finalConsonantCount: UInt32 = 28

    /// Jongseong index meaning "this syllable ends in a vowel".
    public static let noFinalConsonant = 0

    /// Jongseong index of `ㄹ`.
    ///
    /// `ㄹ` is the one final consonant that patterns with open syllables for
    /// `-로`, so it has to be told apart from every other 받침 rather than
    /// folded into a yes/no answer.
    public static let rieulFinalConsonant = 8

    /// The 받침 index of a syllable, or `nil` when the character is not one
    /// Hangul syllable.
    ///
    /// `nil` is the fail-closed answer, and every caller treats it as "propose
    /// nothing". Latin letters, digits, isolated jamo, and emoji all land here,
    /// which is why a token such as `Python을` is never rewritten: its particle
    /// depends on a reading this code cannot know.
    public static func finalConsonant(of character: Character) -> Int? {
        // A draft pasted from another app can arrive canonically decomposed, in
        // which case one grapheme holds several scalars. Composing a throwaway
        // copy keeps the arithmetic valid without rewriting the draft itself,
        // whose UTF-16 offsets must stay exactly as the target app reported.
        let composed = String(character).precomposedStringWithCanonicalMapping
        var scalars = composed.unicodeScalars.makeIterator()
        guard let scalar = scalars.next(), scalars.next() == nil else { return nil }
        guard scalar.value >= syllableBase, scalar.value <= syllableEnd else { return nil }
        return Int((scalar.value - syllableBase) % finalConsonantCount)
    }

    public static func isSyllable(_ character: Character) -> Bool {
        finalConsonant(of: character) != nil
    }

    /// Whether every character is one Hangul syllable.
    ///
    /// Mixed tokens such as `v2버전` are rejected on purpose. Their last
    /// syllable would answer the 받침 question, but a token that also contains
    /// Latin or digits is far more likely to be an identifier than prose, and a
    /// missed repair is always preferable to editing an identifier.
    public static func isAllSyllables(_ value: Substring) -> Bool {
        !value.isEmpty && value.allSatisfy { isSyllable($0) }
    }
}
