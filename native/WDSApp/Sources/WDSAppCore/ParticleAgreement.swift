import Foundation

/// Repairs Korean particles whose spelling is fixed by the preceding 받침.
///
/// The textbook rule is symmetric — read the 받침, then pick the particle — but
/// Korean orthography is not. A naive reading rewrites the ordinary words
/// `사과`, `국가`, `경로`, and `먹는` into `사와`, `국이`, `경으로`, and
/// `먹은`, because Sino-Korean suffixes and verb endings occupy the same
/// syllables that particles do. Distinguishing them needs a dictionary and a
/// morphological analyzer, and WDS has neither by design.
///
/// So only the asymmetric directions are implemented: the ones where the
/// observed spelling cannot plausibly be anything but a mistyped particle. Each
/// rule records the collision that admits or excludes it, and every excluded
/// direction is named so it is not "helpfully" added back later.
public enum ParticleAgreement {
    /// Required 받침 state of the syllable in front of the observed particle.
    private enum StemShape {
        /// Any final consonant.
        case closed
        /// No final consonant.
        case open
        /// No final consonant, or `ㄹ`, which `-로` treats the same way.
        case openOrRieul
        /// `ㄹ` specifically.
        case rieul

        func admits(_ finalConsonant: Int) -> Bool {
            switch self {
            case .closed:
                return finalConsonant != HangulSyllable.noFinalConsonant
            case .open:
                return finalConsonant == HangulSyllable.noFinalConsonant
            case .openOrRieul:
                return finalConsonant == HangulSyllable.noFinalConsonant
                    || finalConsonant == HangulSyllable.rieulFinalConsonant
            case .rieul:
                return finalConsonant == HangulSyllable.rieulFinalConsonant
            }
        }
    }

    private struct Rule {
        let observed: String
        let corrected: String
        let stem: StemShape
        /// Token endings that are ordinary words rather than stem + particle.
        ///
        /// Matched as suffixes, because protecting `가을` has to protect
        /// `늦가을` too.
        let protectedEndings: [String]
    }

    private static let rules: [Rule] = [
        // `를` ends no Korean morpheme, so a 받침 in front of it is an
        // object-particle typo and never a word that merely looks like one.
        // Verb stems that end in 받침 take `-을`, not `-를`, so there is no
        // ending to collide with either.
        Rule(observed: "를", corrected: "을", stem: .closed, protectedEndings: []),

        // The mirror direction needs a blocklist: a few nouns and every
        // ㅅ-irregular `-을` form really do follow an open syllable.
        Rule(observed: "을", corrected: "를", stem: .open, protectedEndings: [
            "가을", "마을", "노을", "모을",
            "지을", "이을", "나을", "부을", "그을", "저을",
        ]),

        // `-으로` is two syllables and effectively never sits inside one
        // morpheme, which makes both the open and the ㄹ direction safe. The
        // reverse (`로` → `으로`) is excluded because Sino-Korean `-로` is
        // productive after 받침: 경로, 진로, 선로, 통로, 회로.
        Rule(observed: "으로", corrected: "로", stem: .openOrRieul, protectedEndings: []),

        // 오다 only conjugates onto an open syllable (나와, 들어와, 찾아와), so
        // a 받침 in front of `와` is the comitative particle. The reverse
        // (`과` → `와`) is excluded because Sino-Korean `-과` is productive
        // after an open syllable: 사과, 내과, 치과, 학과, 교과.
        Rule(observed: "와", corrected: "과", stem: .closed, protectedEndings: [
            // 眼窩. The one common noun that is 받침 + `와` on its own.
            "안와",
        ]),

        // `-께` is the honorific dative and attaches to nouns ending in
        // 님·분·씨·니, none of which end in ㄹ. A ㄹ 받침 in front of it is the
        // `-ㄹ게` ending misspelled, which is the most common Korean ending
        // error in fast typing.
        Rule(observed: "께", corrected: "게", stem: .rieul, protectedEndings: []),
        Rule(observed: "께요", corrected: "게요", stem: .rieul, protectedEndings: []),
        Rule(observed: "껄", corrected: "걸", stem: .rieul, protectedEndings: ["껄껄"]),
    ]

    /// Longest particle first, so `할께요` is read as `-께요` instead of
    /// stopping at a shorter rule that cannot describe it.
    private static let orderedRules = rules.sorted {
        $0.observed.count > $1.observed.count
    }

    /// Every particle repair in the draft, at most one per token.
    ///
    /// The reported span is the whole token rather than the particle alone. A
    /// bare `를` occurs many times in an ordinary draft, and the downstream
    /// write path refuses any target that is not unique, so a particle-sized
    /// span would be rejected before it could ever be applied.
    public static func repairs(in draft: String) -> [DraftSpanRepair] {
        DraftTokenScanner.tokenRanges(in: draft).compactMap { token in
            repair(forTokenAt: token, in: draft)
        }
    }

    private static func repair(
        forTokenAt token: Range<String.Index>,
        in draft: String
    ) -> DraftSpanRepair? {
        let text = draft[token]

        for rule in orderedRules {
            // A strict inequality keeps the stem non-empty, so a draft that
            // contains a bare particle is left alone.
            guard text.count > rule.observed.count,
                  text.hasSuffix(rule.observed),
                  !rule.protectedEndings.contains(where: { text.hasSuffix($0) })
            else { continue }

            let stemEnd = draft.index(token.upperBound, offsetBy: -rule.observed.count)
            let stem = draft[token.lowerBound..<stemEnd]
            guard HangulSyllable.isAllSyllables(stem),
                  let last = stem.last,
                  let finalConsonant = HangulSyllable.finalConsonant(of: last),
                  rule.stem.admits(finalConsonant)
            else { continue }

            return DraftSpanRepair(
                range: token,
                replacement: String(stem) + rule.corrected
            )
        }
        return nil
    }
}
