import Foundation

/// The fixed vocabulary the analyzer recognises.
///
/// Nothing here is learned from the user, and nothing is inferred by stemming
/// or similarity. Every entry is an explicit form, which is what keeps the
/// analyzer stateless and repeatable.
///
/// The lists are split by *where a form can safely be removed*, not by how rude
/// it is. A true interjection carries no reference, so it can be lifted out of
/// any position. A word that can be the object or the predicate of the sentence
/// cannot: deleting the tail of `이 코드 진짜 병신` leaves `이 코드 진짜`, a
/// fragment whose request is gone. Those forms are therefore only removable
/// when they are the entire draft.
public enum DraftDisfluencyLexicon {
    /// Emotional forms that are pure interjections.
    ///
    /// Safe at the start, at the end, or as a comma-delimited aside, because
    /// none of them can be an argument of the sentence.
    public static let detachableEmotionalMarkers: [String] = sortedLongestFirst([
        "시발아", "씨발아", "시발", "씨발", "ㅅㅂ", "ㅆㅂ",
        "씨빨", "시빨", "씨벌", "시벌", "쓰발", "스발", "슈발",
        "아이씨", "아씨", "에이씨",
        "젠장", "니미", "니미럴", "썅",
        "아이고", "아이구", "아유", "아휴", "에휴", "어휴",
        "하아", "헐", "헉", "으악",
        // `ㅗ` is a real emotional gesture but also the plain name of a vowel, so
        // `ㅗ 발음을 설명해 줘` would lose its own subject. Left out.

        "fuck", "wtf", "ffs", "damn", "goddamn",
        "dammit", "damnit", "goddammit",
        "fml", "omfg", "ugh", "argh", "geez", "sheesh",

        "くそ", "ちくしょう",
    ])

    /// Emotional forms that are only removable when they are the whole draft.
    ///
    /// These are nouns, vocatives, and predicates. `짜증나` or `shit` can be the
    /// only thing the user typed, in which case the draft carries no request at
    /// all — but in mid-sentence they are load-bearing, so no positional rule
    /// may touch them.
    public static let standaloneEmotionalMarkers: [String] = sortedLongestFirst([
        "좆", "좆까", "좆같네", "지랄", "개지랄", "엿같네", "니애미",
        "병신", "병신아", "ㅂㅅ", "ㅄ",
        "개새끼", "개새끼야", "개새", "ㄱㅅㄲ", "ㅅㄲ", "새끼야",
        "미쳤네", "미쳤다", "미치겠네", "미치겠다",
        "짜증나", "짜증나네", "빡친다", "빡쳐", "빡침",
        "환장하겠네", "돌겠네",

        "shit", "crap", "bullshit",
    ])

    /// Forms allowed to be removed from the interior of a sentence.
    ///
    /// The narrowest list on purpose. An interior deletion has prose on both
    /// sides, so a wrong call here damages a sentence that was otherwise fine.
    public static let interiorEmotionalMarkers: [String] = sortedLongestFirst([
        "시발", "씨발", "ㅅㅂ", "ㅆㅂ",
        "씨빨", "시빨", "씨벌", "시벌", "쓰발", "썅",
    ])

    /// Intensifiers that may be dropped in front of an already-negative
    /// evaluation.
    ///
    /// Inflected forms are absent by design. `존나게` can carry a real magnitude
    /// requirement, and the analyzer has no way to tell that apart from emphasis.
    public static let removableIntensifiers: [String] = sortedLongestFirst([
        "존나", "ㅈㄴ", "졸라", "조낸", "존내", "열라",
        "fucking", "freaking", "frigging", "bloody",
    ])

    /// Predicates that already read as negative without the intensifier.
    ///
    /// Matched as a prefix of the following unit, so `구려` also covers
    /// `구리다` and `bad` also covers `badly`.
    public static let independentlyNegativePredicatePrefixes: [String] = [
        "구려", "구리", "별로", "별론", "이상", "답답", "짜증", "엉망", "최악",
        "못하", "못했", "싫", "한심", "어이없", "개판",
        "형편없", "느리", "늦", "망했", "망함", "틀렸", "틀림",
        "헛소리", "개소리", "노답", "부족", "애매", "지겹", "귀찮",
        "열받", "화나", "빡치", "빡침", "쓰레기", "별거없", "이해못",
        "안되", "안돼", "지루", "지저분", "복잡", "아쉽", "실망",

        "bad", "broken", "wrong", "slow", "stupid", "useless",
        "terrible", "awful", "horrible", "ugly", "messy", "confusing",
        "annoying", "garbage", "trash", "worse", "worst", "dumb",
        "buggy", "laggy", "unclear", "pointless", "sloppy", "clunky", "janky",
    ]

    /// Discourse openers that contribute nothing to the request.
    ///
    /// A comma boundary is still required before any of these is considered, and
    /// forms that carry a real relation — `근데`, `그래서`, `actually` — are
    /// absent because removing them drops a contrast, a cause, or a correction.
    public static let detachableOpenings: Set<String> = [
        "아니", "어", "엄", "음", "으음", "저기", "뭐랄까", "있잖아",
        "그", "그게", "그니까", "그러니까", "그니깐", "그러니깐", "그러니",
        "뭐", "뭐지", "뭐냐", "아", "오", "에", "흠", "흠흠", "음음",
        "어우", "자", "야", "저", "참", "엥", "아이참",
        "아무튼", "어쨌든", "하여튼", "여튼", "암튼", "그나저나",

        "well", "um", "uh", "erm", "uhm", "umm", "you know", "i mean",
        "like", "so", "ok", "okay", "alright", "right",
        "hmm", "hm", "ah", "oh", "eh",
        "basically", "honestly", "anyway", "anyways",
        "look", "listen", "yeah", "yep",

        "あの", "えっと", "ええと", "まあ", "なんか", "うーん", "そのー",
    ]

    /// Forms whose immediate repetition is evidence of hesitation.
    ///
    /// Narrower than the openers: repetition only means hesitation for markers
    /// that are contentless on their own. Repeating an arbitrary word is never
    /// treated as evidence.
    public static let hesitationMarkers: Set<String> = [
        "아니", "어", "엄", "음", "으음", "저기",
        "그", "저", "뭐", "아", "에", "흠",
        "well", "um", "uh", "er", "erm", "uhm", "umm",
        "hmm", "hm", "like",
        "あの", "えっと", "まあ", "なんか", "うーん",
    ]

    /// Every emotional form the analyzer can propose, used by the
    /// metalinguistic guard.
    ///
    /// The guard has to cover the whole vocabulary rather than a hand-picked
    /// subset. Otherwise a draft such as `fuck을 지워줘` would have its own
    /// subject deleted, which is the exact opposite of what was asked.
    public static let mentionableEmotionalForms: [String] = sortedLongestFirst(
        Array(Set(
            detachableEmotionalMarkers
                + standaloneEmotionalMarkers
                + removableIntensifiers
        ))
    )

    /// Longest first so that a scanner which stops at its first match still
    /// prefers `씨발아` over the `씨발` contained in it.
    private static func sortedLongestFirst(_ forms: [String]) -> [String] {
        forms.sorted {
            $0.count != $1.count ? $0.count > $1.count : $0 < $1
        }
    }
}
