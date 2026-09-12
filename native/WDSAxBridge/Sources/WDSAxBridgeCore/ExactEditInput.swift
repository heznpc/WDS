import Foundation

/// Both sides of a replacement travel together through stdin, never argv.
public struct ExactEditInput: Codable, Equatable {
    public let target: String
    public let replacement: String
    public static let maximumBytes = 512 * 1_024

    public static func decode(_ data: Data) throws -> ExactEditInput {
        guard data.count <= maximumBytes else { throw ExactEditInputError.tooLarge }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard !value.replacement.isEmpty, value.target != value.replacement,
              !value.target.contains("\0"), !value.replacement.contains("\0"),
              value.target.utf8.count <= 128 * 1_024,
              value.replacement.utf8.count <= 128 * 1_024
        else { throw ExactEditInputError.invalidText }
        return value
    }
}

public enum ExactEditInputError: Error, Equatable {
    case tooLarge
    case invalidText
}
