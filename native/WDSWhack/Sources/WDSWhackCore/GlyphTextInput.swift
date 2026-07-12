import Foundation

public enum GlyphTextInputFailure: Error, Equatable, Sendable {
    case invalidEncoding
    case empty
    case tooLarge
    case tooManyGraphemes
}

public enum GlyphTextInput {
    public static let maximumBytes = 8 * 1_024
    public static let maximumGraphemes = 64

    public static func parse(_ data: Data) -> Result<String, GlyphTextInputFailure> {
        guard data.count <= maximumBytes else {
            return .failure(.tooLarge)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return .failure(.invalidEncoding)
        }
        guard isRenderable(text) else {
            return .failure(.empty)
        }
        guard text.count <= maximumGraphemes else {
            return .failure(.tooManyGraphemes)
        }
        return .success(text)
    }

    public static func isRenderable(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter,
                 .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber,
                 .connectorPunctuation, .dashPunctuation, .openPunctuation,
                 .closePunctuation, .initialPunctuation, .finalPunctuation,
                 .otherPunctuation,
                 .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
                return true
            default:
                return false
            }
        }
    }
}
