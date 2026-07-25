import Foundation

/// A local, offline approximation of how many language-model tokens a piece of
/// text costs.
///
/// WDS never sends drafts to a tokenizer service, so the savings counter cannot
/// know the exact token count a given provider's BPE tokenizer would produce.
/// Instead it approximates the count by classifying each Unicode scalar into a
/// script bucket and summing a per-bucket weight. The weights are calibrated
/// against the behaviour of modern byte-level BPE tokenizers (OpenAI o200k /
/// cl100k, Anthropic's tokenizer) on mixed Korean/English text.
///
/// The result is deliberately labelled as an estimate ("추정") wherever it is
/// shown to the user. It is meant to convey the *magnitude* of what a habitual
/// phrase costs, not an exact billing figure. The weights are exposed so they
/// can be re-tuned without touching the classification logic.
public struct TokenEstimator: Equatable, Sendable {
    /// Tokens-per-scalar weights for each script bucket.
    ///
    /// Defaults lean toward the denser, improved tokenizers shipped by current
    /// providers rather than older ones, and stay slightly conservative so the
    /// counter does not overstate savings.
    public struct Weights: Equatable, Sendable {
        /// A precomposed Hangul syllable (가–힣). The dominant bucket for
        /// Korean prose and the main driver of Korean token cost.
        public var hangulSyllable: Double
        /// An isolated Hangul jamo (rare in finished text).
        public var hangulJamo: Double
        /// A CJK ideograph or Japanese kana.
        public var cjk: Double
        /// A Latin (or other alphabetic, non-CJK) letter. Per-character, so a
        /// run approximates the "~4 characters per token" rule of thumb.
        public var latin: Double
        /// A decimal digit. Providers group digits into short runs.
        public var digit: Double
        /// Punctuation or a symbol that usually merges into an adjacent token.
        public var punctuation: Double
        /// A line break, which is generally its own token.
        public var newline: Double
        /// Inline whitespace, which folds into the following token.
        public var whitespace: Double
        /// Anything else (emoji, uncommon symbols), which tends to cost several
        /// tokens per scalar.
        public var other: Double

        public init(
            hangulSyllable: Double,
            hangulJamo: Double,
            cjk: Double,
            latin: Double,
            digit: Double,
            punctuation: Double,
            newline: Double,
            whitespace: Double,
            other: Double
        ) {
            self.hangulSyllable = hangulSyllable
            self.hangulJamo = hangulJamo
            self.cjk = cjk
            self.latin = latin
            self.digit = digit
            self.punctuation = punctuation
            self.newline = newline
            self.whitespace = whitespace
            self.other = other
        }

        public static let `default` = Weights(
            hangulSyllable: 1.2,
            hangulJamo: 1.0,
            cjk: 1.0,
            latin: 0.28,
            digit: 0.4,
            punctuation: 0.35,
            newline: 1.0,
            whitespace: 0.0,
            other: 2.0
        )
    }

    public var weights: Weights

    public init(weights: Weights = .default) {
        self.weights = weights
    }

    /// Estimates the token cost of `text`.
    ///
    /// Empty or whitespace-only text estimates to zero; any other content
    /// estimates to at least one token, because a real tokenizer never encodes
    /// non-empty text as zero tokens (a single Latin letter would otherwise
    /// round down to 0). A CRLF pair counts as one line break, matching how
    /// byte-level tokenizers merge "\r\n", so estimates do not depend on the
    /// line-ending style of pasted text.
    public func estimate(_ text: String) -> Int {
        var total = 0.0
        var previousWasCarriageReturn = false
        for scalar in text.unicodeScalars {
            if scalar.value == 0x0A && previousWasCarriageReturn {
                previousWasCarriageReturn = false
                continue
            }
            previousWasCarriageReturn = scalar.value == 0x0D
            total += weight(for: scalar)
        }
        guard total > 0 else { return 0 }
        return max(1, Int(total.rounded()))
    }

    /// Convenience estimate using the default weights.
    public static func estimate(_ text: String) -> Int {
        TokenEstimator().estimate(text)
    }

    private func weight(for scalar: Unicode.Scalar) -> Double {
        switch Self.classify(scalar) {
        case .hangulSyllable: return weights.hangulSyllable
        case .hangulJamo: return weights.hangulJamo
        case .cjk: return weights.cjk
        case .latin: return weights.latin
        case .digit: return weights.digit
        case .newline: return weights.newline
        case .whitespace: return weights.whitespace
        case .punctuation: return weights.punctuation
        case .other: return weights.other
        }
    }

    private enum ScalarClass {
        case hangulSyllable, hangulJamo, cjk, latin, digit, newline, whitespace, punctuation, other
    }

    private static func classify(_ scalar: Unicode.Scalar) -> ScalarClass {
        let value = scalar.value

        if value == 0x0A || value == 0x0D { return .newline }
        if (0xAC00...0xD7A3).contains(value) { return .hangulSyllable }
        if (0x1100...0x11FF).contains(value)
            || (0x3130...0x318F).contains(value)
            || (0xA960...0xA97F).contains(value)
            || (0xD7B0...0xD7FF).contains(value) {
            return .hangulJamo
        }
        if (0x4E00...0x9FFF).contains(value)
            || (0x3400...0x4DBF).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0x3040...0x30FF).contains(value)
            || (0x20000...0x2FA1F).contains(value) {
            return .cjk
        }
        if CharacterSet.decimalDigits.contains(scalar) { return .digit }
        if CharacterSet.whitespaces.contains(scalar) { return .whitespace }
        if scalar.properties.isAlphabetic { return .latin }

        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation,
             .closePunctuation, .initialPunctuation, .finalPunctuation,
             .otherPunctuation, .mathSymbol, .currencySymbol, .modifierSymbol:
            return .punctuation
        default:
            return .other
        }
    }
}
