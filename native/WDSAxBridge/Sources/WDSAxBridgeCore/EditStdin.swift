import Foundation

/// Why a replace command's stdin payload could not be parsed.
public enum EditStdinError: Error, Equatable, Sendable {
    case tooLarge
    case missingSeparator
    case invalidEncoding
}

/// Upper bound on the replace command's stdin payload (target + NUL +
/// replacement). The post-edit value is separately bounded by the 64 KiB focused
/// value ceiling before any write, so this only caps the transport.
public let maximumEditStdinByteCount = 128 * 1_024

/// Splits the replace command's stdin payload into its two UTF-8 fields.
///
/// The framing is `target` + a single NUL byte + `replacement`. This rejects
/// oversize input, a missing separator, any NUL inside the replacement, and
/// non-UTF-8 bytes. Emptiness of the target or replacement is intentionally not
/// judged here; the caller applies the command-specific rules (a target must be
/// non-empty for every command, and a replacement must be non-empty for replace).
public func parseEditStdin(_ data: Data) -> Result<(target: String, replacement: String), EditStdinError> {
    guard data.count <= maximumEditStdinByteCount else {
        return .failure(.tooLarge)
    }
    guard let separatorIndex = data.firstIndex(of: 0) else {
        return .failure(.missingSeparator)
    }
    let targetData = data[data.startIndex..<separatorIndex]
    let replacementData = data[data.index(after: separatorIndex)...]
    guard !replacementData.contains(0),
          let target = String(data: targetData, encoding: .utf8),
          let replacement = String(data: replacementData, encoding: .utf8)
    else {
        return .failure(.invalidEncoding)
    }
    return .success((target, replacement))
}
