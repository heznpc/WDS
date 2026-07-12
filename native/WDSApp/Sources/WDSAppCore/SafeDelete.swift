import CryptoKit
import Foundation

public struct OverlayRectangle: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// The only state retained between inspect and delete. It deliberately contains
/// no focused-input value and no target phrase.
public struct SafeDeleteInspection: Equatable, Sendable {
    public let valueSHA256: String
    public let expectedResultSHA256: String
    public let processIdentifier: Int32
    public let rangeLocation: Int
    public let rangeLength: Int
    public let overlayRectangle: OverlayRectangle
    public let overlayIsEstimated: Bool

    public init(
        valueSHA256: String,
        expectedResultSHA256: String,
        processIdentifier: Int32,
        rangeLocation: Int,
        rangeLength: Int,
        overlayRectangle: OverlayRectangle,
        overlayIsEstimated: Bool = false
    ) {
        self.valueSHA256 = valueSHA256
        self.expectedResultSHA256 = expectedResultSHA256
        self.processIdentifier = processIdentifier
        self.rangeLocation = rangeLocation
        self.rangeLength = rangeLength
        self.overlayRectangle = overlayRectangle
        self.overlayIsEstimated = overlayIsEstimated
    }
}

public enum SafeDeleteFailure: Error, Equatable, Sendable {
    case malformedResponse
    case bridge(code: String?)
    case duplicateTarget
    case processChanged
    case invalidDigest
    case invalidRange
    case noUsableBounds
    case deleteNotVerified

    public var status: String {
        switch self {
        case .duplicateTarget:
            return "Exact phrase is duplicated; nothing was deleted"
        case .processChanged:
            return "Target app changed; nothing was deleted"
        case .invalidDigest, .invalidRange:
            return "Draft changed or inspection mismatched; nothing was deleted"
        case .noUsableBounds:
            return "Focused phrase has no usable screen bounds"
        case .deleteNotVerified:
            return "Deletion could not be verified"
        case .bridge(let code):
            switch code {
            case "accessibility_permission_required":
                return "Accessibility permission required"
            case "secure_field_ignored":
                return "Secure fields are never read or edited"
            case "security_metadata_unavailable":
                return "Field security could not be verified; nothing was read or deleted"
            case "focused_value_too_large":
                return "Focused draft is too large; nothing was read or deleted"
            case "target_not_found":
                return "Exact phrase was not found; nothing was deleted"
            case "ambiguous_target":
                return "Exact phrase is duplicated; nothing was deleted"
            case "value_digest_mismatch", "target_range_mismatch":
                return "Draft changed; nothing was deleted"
            case "target_process_changed", "target_app_not_frontmost",
                 "focused_process_unavailable", "focused_process_mismatch":
                return "Target app or focus changed; nothing was deleted"
            case "focused_element_not_editable", "app_focused_element_unavailable",
                 "focused_element_unavailable", "focused_value_unavailable":
                return "Focus the editable target input, then retry"
            case "delete_not_supported":
                return "This input does not support safe deletion"
            case "delete_verification_timed_out":
                return "Deletion write was accepted but its result could not be verified"
            default:
                return "Safe deletion failed"
            }
        case .malformedResponse:
            return "Safe deletion response was rejected"
        }
    }
}

public enum SafeDeleteResponseValidator {
    private static let maximumResponseBytes = 8 * 1_024 * 1_024

    public static func parseInspection(
        _ data: Data,
        exactPhrase: String,
        expectedProcessIdentifier: Int32
    ) -> Result<SafeDeleteInspection, SafeDeleteFailure> {
        guard !exactPhrase.isEmpty,
              let object = object(from: data)
        else { return .failure(.malformedResponse) }
        guard object["ok"] as? Bool == true else {
            return .failure(bridgeFailure(from: object))
        }
        guard integer(object["occurrenceCount"]) == 1 else {
            return .failure(.duplicateTarget)
        }
        guard let digest = object["valueSHA256"] as? String,
              isSHA256(digest),
              let currentValue = object["currentValue"] as? String,
              sha256(currentValue) == digest
        else { return .failure(.invalidDigest) }
        guard integer(object["targetProcessIdentifier"]) == Int(expectedProcessIdentifier) else {
            return .failure(.processChanged)
        }
        guard let range = object["utf16Range"] as? [String: Any],
              let location = integer(range["location"]),
              let length = integer(range["length"]),
              location >= 0, length > 0,
              length == (exactPhrase as NSString).length,
              location <= Int.max - length
        else { return .failure(.invalidRange) }

        let source = currentValue as NSString
        let nsRange = NSRange(location: location, length: length)
        guard NSMaxRange(nsRange) <= source.length,
              source.substring(with: nsRange) == exactPhrase
        else { return .failure(.invalidRange) }
        guard exactOccurrenceCount(of: exactPhrase, in: currentValue) == 1 else {
            return .failure(.duplicateTarget)
        }

        let expectedResult = source.replacingCharacters(in: nsRange, with: "")
        guard let geometry = OverlayGeometryResolver.resolve(
            exactBounds: rectangle(from: object["targetBounds"]),
            focusedElementFrame: rectangle(from: object["focusedElementFrame"]),
            currentValue: currentValue,
            target: exactPhrase,
            utf16Location: location,
            utf16Length: length
        )
        else { return .failure(.noUsableBounds) }

        return .success(SafeDeleteInspection(
            valueSHA256: digest,
            expectedResultSHA256: sha256(expectedResult),
            processIdentifier: expectedProcessIdentifier,
            rangeLocation: location,
            rangeLength: length,
            overlayRectangle: geometry.rectangle,
            overlayIsEstimated: geometry.isEstimated
        ))
    }

    public static func validateDeletion(
        _ data: Data,
        against inspection: SafeDeleteInspection
    ) -> Result<Void, SafeDeleteFailure> {
        guard let object = object(from: data) else {
            return .failure(.malformedResponse)
        }
        guard object["ok"] as? Bool == true else {
            return .failure(bridgeFailure(from: object))
        }
        guard object["command"] as? String == "delete",
              object["deleted"] as? Bool == true,
              integer(object["occurrenceCount"]) == 1,
              integer(object["targetProcessIdentifier"]) == Int(inspection.processIdentifier),
              object["valueSHA256"] as? String == inspection.valueSHA256,
              let range = object["utf16Range"] as? [String: Any],
              integer(range["location"]) == inspection.rangeLocation,
              integer(range["length"]) == inspection.rangeLength,
              let valuePrecondition = object["valuePrecondition"] as? [String: Any],
              valuePrecondition["expectedSHA256"] as? String == inspection.valueSHA256,
              valuePrecondition["actualSHA256"] as? String == inspection.valueSHA256,
              let resultValue = object["resultValue"] as? String,
              sha256(resultValue) == inspection.expectedResultSHA256,
              let method = object["deletionMethod"] as? String,
              method == "selectedText" || method == "wholeValueFallback"
        else { return .failure(.deleteNotVerified) }
        return .success(())
    }

    private static func object(from data: Data) -> [String: Any]? {
        guard data.count <= maximumResponseBytes else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func bridgeFailure(from object: [String: Any]) -> SafeDeleteFailure {
        let error = object["error"] as? [String: Any]
        return .bridge(code: error?["code"] as? String)
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded(.towardZero) == double,
              double >= Double(Int.min), double <= Double(Int.max)
        else { return nil }
        return Int(double)
    }

    private static func rectangle(from value: Any?) -> OverlayRectangle? {
        guard let dictionary = value as? [String: Any],
              let x = finiteDouble(dictionary["x"]),
              let y = finiteDouble(dictionary["y"]),
              let width = finiteDouble(dictionary["width"]),
              let height = finiteDouble(dictionary["height"]),
              width > 0, height > 0,
              width <= 10_000, height <= 10_000,
              abs(x) <= 100_000, abs(y) <= 100_000
        else { return nil }
        return OverlayRectangle(x: x, y: y, width: width, height: height)
    }

    private static func finiteDouble(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (97...102).contains($0.value)
        }
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func exactOccurrenceCount(of target: String, in value: String) -> Int {
        let source = value as NSString
        let needle = target as NSString
        var count = 0
        var location = 0
        while location <= source.length - needle.length {
            let range = source.range(
                of: target,
                options: [],
                range: NSRange(location: location, length: source.length - location)
            )
            guard range.location != NSNotFound else { break }
            count += 1
            location = NSMaxRange(range)
        }
        return count
    }
}
