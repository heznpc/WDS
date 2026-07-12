import Foundation

public enum TerminalWireViolation: Error, Equatable, Sendable {
    case messageTooLarge
    case truncatedHeader
    case truncatedBody
    case trailingBytes
}

public func encodeTerminalWireFrame<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let body = try encoder.encode(value)
    guard body.count <= wdsMaximumWireMessageBytes else {
        throw TerminalWireViolation.messageTooLarge
    }

    var length = UInt32(body.count).bigEndian
    var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
    frame.append(body)
    return frame
}

public func decodeTerminalWireFrame<T: Decodable>(
    _ type: T.Type,
    from frame: Data
) throws -> T {
    guard frame.count >= MemoryLayout<UInt32>.size else {
        throw TerminalWireViolation.truncatedHeader
    }

    let bodyLength = frame.prefix(MemoryLayout<UInt32>.size).reduce(UInt32(0)) {
        ($0 << 8) | UInt32($1)
    }
    guard bodyLength <= UInt32(wdsMaximumWireMessageBytes) else {
        throw TerminalWireViolation.messageTooLarge
    }

    let expectedCount = MemoryLayout<UInt32>.size + Int(bodyLength)
    guard frame.count >= expectedCount else {
        throw TerminalWireViolation.truncatedBody
    }
    guard frame.count == expectedCount else {
        throw TerminalWireViolation.trailingBytes
    }

    return try JSONDecoder().decode(
        type,
        from: frame.dropFirst(MemoryLayout<UInt32>.size)
    )
}
