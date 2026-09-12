import Foundation

/// Repairs a closed set of Korean spellings whose wrong form is not a word.
///
/// This is deliberately a table and not a grammar. Every pair below has the
/// property that the observed spelling has no valid reading at all, so choosing
/// the corrected form cannot change what the draft means. Confusions that
/// depend on context — 로써/로서, 맞추다/맞히다, 던지/든지, 낫다/낳다, and
/// `안 되다` used correctly — are absent for exactly that reason: resolving them
/// needs to know the sentence's intent, and guessing wrong rewrites the user's
/// request instead of fixing it.
public enum OrthographyRepair {
    private struct Rule {
        let observed: String
        let corrected: String
    }

    /// Ending confusions (어미). These are the errors that survive into typed
    /// prompts because the wrong form is pronounced identically to the right
    /// one.
    private static let endingRules: [Rule] = [
        // 되/돼. `돼` is the contraction of `되어`, so `되` before a
        // vowel-initial ending has no valid reading.
        Rule(observed: "되요", corrected: "돼요"),
        Rule(observed: "되서", corrected: "돼서"),
        Rule(observed: "됬", corrected: "됐"),
        Rule(observed: "뵈요", corrected: "봬요"),

        // 안/않. `않` is a bound negative predicate and cannot stand in front of
        // another verb stem.
        Rule(observed: "않되", corrected: "안 되"),
        Rule(observed: "않돼", corrected: "안 돼"),
        Rule(observed: "않하", corrected: "안 하"),
        Rule(observed: "않한", corrected: "안 한"),
        Rule(observed: "않해", corrected: "안 해"),

        // -려고 / -으려고. The inserted `ㄹ` is a pronunciation spelling.
        // `갈려`, `볼려`, and `줄려` are spelled out in full because 갈리다 and
        // 줄이다 produce real `갈려`/`줄여` forms of their own.
        Rule(observed: "할려", corrected: "하려"),
        Rule(observed: "될려", corrected: "되려"),
        Rule(observed: "갈려고", corrected: "가려고"),
        Rule(observed: "갈려면", corrected: "가려면"),
        Rule(observed: "볼려고", corrected: "보려고"),
        Rule(observed: "볼려면", corrected: "보려면"),
        Rule(observed: "줄려고", corrected: "주려고"),
        Rule(observed: "먹을려", corrected: "먹으려"),

        // Copula. `예요` follows an open syllable and `이에요` follows a 받침,
        // which leaves `이예요` with no valid position at all.
        Rule(observed: "아니예요", corrected: "아니에요"),
        Rule(observed: "이예요", corrected: "이에요"),
        Rule(observed: "뭐에요", corrected: "뭐예요"),

        // Adverbial -이 written as -히. Only the stems that take -이 are listed;
        // 꼼꼼히 and 조용히 really are -히.
        Rule(observed: "깨끗히", corrected: "깨끗이"),
        Rule(observed: "틈틈히", corrected: "틈틈이"),
        Rule(observed: "일일히", corrected: "일일이"),
        Rule(observed: "번번히", corrected: "번번이"),
        Rule(observed: "샅샅히", corrected: "샅샅이"),

        // Pre-1988 orthography, still produced by phonetic typing.
        Rule(observed: "읍니다", corrected: "습니다"),
        Rule(observed: "함니다", corrected: "합니다"),
        Rule(observed: "슴니다", corrected: "습니다"),

        Rule(observed: "어쨋든", corrected: "어쨌든"),
    ]

    /// Vocabulary errors (잘못된 어휘) where the written form is not a word.
    private static let vocabularyRules: [Rule] = [
        Rule(observed: "어떻해", corrected: "어떡해"),
        Rule(observed: "어떡게", corrected: "어떻게"),
        Rule(observed: "어의없", corrected: "어이없"),
        Rule(observed: "몇일", corrected: "며칠"),
        Rule(observed: "역활", corrected: "역할"),
        Rule(observed: "계시판", corrected: "게시판"),
        Rule(observed: "설레임", corrected: "설렘"),
        Rule(observed: "갯수", corrected: "개수"),
        Rule(observed: "숫가락", corrected: "숟가락"),
        Rule(observed: "귀뜸", corrected: "귀띔"),
        Rule(observed: "나름데로", corrected: "나름대로"),
        Rule(observed: "만듬", corrected: "만듦"),
        Rule(observed: "오랫만", corrected: "오랜만"),
        // 왠 is a contraction of 왜인, so only `왠지` can mean "somehow".
        Rule(observed: "웬지", corrected: "왠지"),
        Rule(observed: "동거동락", corrected: "동고동락"),
    ]

    /// Longest first, so `아니예요` is repaired as a whole instead of being cut
    /// short by the `이예요` rule that also matches inside it.
    private static let orderedRules = (endingRules + vocabularyRules).sorted {
        $0.observed.count > $1.observed.count
    }

    /// Every spelling repair in the draft, at most one per token.
    ///
    /// The reported span is the whole token, both because a repair can shift a
    /// word boundary (`않되` becomes `안 되`) and because the downstream write
    /// path refuses any target that is not unique in the draft.
    public static func repairs(in draft: String) -> [DraftSpanRepair] {
        DraftTokenScanner.tokenRanges(in: draft).compactMap { token in
            repair(forTokenAt: token, in: draft)
        }
    }

    private static func repair(
        forTokenAt token: Range<String.Index>,
        in draft: String
    ) -> DraftSpanRepair? {
        // Restricting repairs to all-Hangul tokens keeps identifiers, file
        // names, and transliterated code out of the table's reach even when they
        // happen to contain one of these syllable sequences.
        guard HangulSyllable.isAllSyllables(draft[token]) else { return nil }
        let text = String(draft[token])

        for rule in orderedRules {
            guard let found = text.range(of: rule.observed) else { continue }
            let corrected = String(text[text.startIndex..<found.lowerBound])
                + rule.corrected
                + String(text[found.upperBound...])
            return DraftSpanRepair(range: token, replacement: corrected)
        }
        return nil
    }
}
