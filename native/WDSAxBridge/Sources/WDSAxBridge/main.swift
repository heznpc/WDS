import ApplicationServices
import AppKit
import Darwin
import Foundation
import WDSAxBridgeCore

private enum Command: String {
    case inspect
    case delete
    case replace
}

private struct CLIOptions {
    let command: Command
    let target: String
    let bundleIdentifier: String?
    let deletePrecondition: DeletePrecondition?
    let replacement: String?
}

private struct BridgeFailure: Error, @unchecked Sendable {
    let code: String
    let message: String
    let details: [String: Any]

    init(_ code: String, _ message: String, details: [String: Any] = [:]) {
        self.code = code
        self.message = message
        self.details = details
    }
}

private struct Inspection {
    let element: AXUIElement
    let value: String
    let target: String
    let range: NSRange
    let occurrenceCount: Int
    let elementFrame: CGRect?
    let targetBounds: CGRect?
    let requestedBundleIdentifier: String?
    let processIdentifier: pid_t
}

private enum AXSecurityMetadataRead {
    case value(String)
    case absent
    case unavailable(axError: AXError?, reason: String)

    var policyValue: FocusedValueSecurityMetadata {
        switch self {
        case .value(let value):
            return .value(value)
        case .absent:
            return .absent
        case .unavailable:
            return .unavailable
        }
    }

    var stringValue: String? {
        guard case .value(let value) = self else { return nil }
        return value
    }
}

private let helpText = """
Usage:
  wds-ax-bridge inspect --target <text> [--bundle-id <id>]
  printf %s <text> | wds-ax-bridge inspect --target-stdin [--bundle-id <id>]
  wds-ax-bridge delete  --target <text> [--bundle-id <id>] \
    --expected-value-sha256 <digest> --expected-pid <pid> \
    --expected-range-location <utf16-offset> --expected-range-length <utf16-length>

Commands:
  inspect   Read the focused editable element and report the exact UTF-16 range.
  delete    Delete only that exact range. This command never sends or submits text.

Safety:
  The target must have exactly one occurrence. If the target occurs more than once,
  the bridge proceeds only when one occurrence is already selected exactly.
  Accessibility permission is checked without opening a permission prompt.
  With --bundle-id, only that running app's focused accessibility element is used.
  --target-stdin keeps the target out of the process argument list.
  Delete requires the full-draft digest, process ID, and range returned by inspect.
  It also requires that exact process to remain active and frontmost at each write.
"""

@main
private enum WDSAxBridge {
    static func main() {
        do {
            guard let options = try parseOptions(Array(CommandLine.arguments.dropFirst())) else {
                print(helpText)
                return
            }

            let inspection = try inspectFocusedElement(
                target: options.target,
                bundleIdentifier: options.bundleIdentifier
            )
            var payload = inspectionPayload(inspection, command: options.command)

            if options.command == .delete {
                guard let precondition = options.deletePrecondition else {
                    throw BridgeFailure(
                        "missing_delete_precondition",
                        "Delete requires the digest, process ID, and UTF-16 range returned by inspect."
                    )
                }
                let result = try applyExactEdit(from: inspection, precondition: precondition, replacement: "")
                payload["deleted"] = true
                payload["deletionMethod"] = result.method
                payload["resultValue"] = result.value
                payload["valuePrecondition"] = [
                    "expectedSHA256": precondition.valueSHA256,
                    "actualSHA256": sha256UTF8(inspection.value),
                ]
            }

            if options.command == .replace {
                guard let precondition = options.deletePrecondition else {
                    throw BridgeFailure(
                        "missing_delete_precondition",
                        "Replace requires the digest, process ID, and UTF-16 range returned by inspect."
                    )
                }
                guard let replacement = options.replacement, !replacement.isEmpty else {
                    throw BridgeFailure(
                        "missing_replacement",
                        "Replace requires a non-empty replacement supplied over --edit-stdin."
                    )
                }
                let result = try applyExactEdit(
                    from: inspection,
                    precondition: precondition,
                    replacement: replacement
                )
                payload["replaced"] = true
                payload["deletionMethod"] = result.method
                payload["resultValue"] = result.value
                payload["valuePrecondition"] = [
                    "expectedSHA256": precondition.valueSHA256,
                    "actualSHA256": sha256UTF8(inspection.value),
                ]
            }

            payload["ok"] = true
            writeJSON(payload)
        } catch let failure as BridgeFailure {
            writeJSON([
                "ok": false,
                "error": [
                    "code": failure.code,
                    "message": failure.message,
                    "details": failure.details,
                ],
            ])
            exit(EXIT_FAILURE)
        } catch {
            writeJSON([
                "ok": false,
                "error": [
                    "code": "unexpected_error",
                    "message": String(describing: error),
                    "details": [:],
                ],
            ])
            exit(EXIT_FAILURE)
        }
    }
}

private func parseOptions(_ arguments: [String]) throws -> CLIOptions? {
    if arguments.isEmpty || arguments == ["--help"] || arguments == ["-h"] {
        return nil
    }

    guard let command = Command(rawValue: arguments[0]) else {
        throw BridgeFailure(
            "invalid_command",
            "Expected 'inspect', 'delete', or 'replace'.",
            details: ["received": arguments[0]]
        )
    }

    var target: String?
    var targetFromStandardInput = false
    var editFromStandardInput = false
    var bundleIdentifier: String?
    var expectedValueSHA256: String?
    var expectedProcessIdentifier: pid_t?
    var expectedRangeLocation: Int?
    var expectedRangeLength: Int?
    var index = 1
    while index < arguments.count {
        switch arguments[index] {
        case "--target":
            let valueIndex = index + 1
            guard valueIndex < arguments.count else {
                throw BridgeFailure("missing_target", "--target requires a value.")
            }
            guard target == nil, !targetFromStandardInput, !editFromStandardInput else {
                throw BridgeFailure("duplicate_target", "Specify exactly one target source.")
            }
            target = arguments[valueIndex]
            index += 2
        case "--target-stdin":
            guard target == nil, !targetFromStandardInput, !editFromStandardInput else {
                throw BridgeFailure("duplicate_target", "Specify exactly one target source.")
            }
            targetFromStandardInput = true
            index += 1
        case "--edit-stdin":
            guard command == .replace else {
                throw BridgeFailure("edit_stdin_requires_replace", "--edit-stdin is valid only with the replace command.")
            }
            guard target == nil, !targetFromStandardInput, !editFromStandardInput else {
                throw BridgeFailure("duplicate_target", "Specify exactly one target source.")
            }
            editFromStandardInput = true
            index += 1
        case "--bundle-id":
            let valueIndex = index + 1
            guard valueIndex < arguments.count else {
                throw BridgeFailure("missing_bundle_id", "--bundle-id requires a value.")
            }
            guard bundleIdentifier == nil else {
                throw BridgeFailure("duplicate_bundle_id", "--bundle-id may be specified only once.")
            }
            guard !arguments[valueIndex].isEmpty else {
                throw BridgeFailure("empty_bundle_id", "The bundle identifier must not be empty.")
            }
            bundleIdentifier = arguments[valueIndex]
            index += 2
        case "--expected-value-sha256":
            let valueIndex = index + 1
            guard valueIndex < arguments.count else {
                throw BridgeFailure("missing_expected_digest", "--expected-value-sha256 requires a value.")
            }
            guard expectedValueSHA256 == nil else {
                throw BridgeFailure("duplicate_expected_digest", "--expected-value-sha256 may be specified only once.")
            }
            guard isCanonicalSHA256(arguments[valueIndex]) else {
                throw BridgeFailure(
                    "invalid_expected_digest",
                    "--expected-value-sha256 must be a lowercase 64-character SHA-256 digest."
                )
            }
            expectedValueSHA256 = arguments[valueIndex]
            index += 2
        case "--expected-pid":
            let valueIndex = index + 1
            guard valueIndex < arguments.count else {
                throw BridgeFailure("missing_expected_pid", "--expected-pid requires a value.")
            }
            guard expectedProcessIdentifier == nil else {
                throw BridgeFailure("duplicate_expected_pid", "--expected-pid may be specified only once.")
            }
            guard let parsed = Int32(arguments[valueIndex]), parsed > 0 else {
                throw BridgeFailure("invalid_expected_pid", "--expected-pid must be a positive 32-bit process ID.")
            }
            expectedProcessIdentifier = parsed
            index += 2
        case "--expected-range-location":
            let valueIndex = index + 1
            guard valueIndex < arguments.count else {
                throw BridgeFailure("missing_expected_range", "--expected-range-location requires a value.")
            }
            guard expectedRangeLocation == nil else {
                throw BridgeFailure("duplicate_expected_range", "--expected-range-location may be specified only once.")
            }
            guard let parsed = Int(arguments[valueIndex]), parsed >= 0 else {
                throw BridgeFailure("invalid_expected_range", "--expected-range-location must be a nonnegative integer.")
            }
            expectedRangeLocation = parsed
            index += 2
        case "--expected-range-length":
            let valueIndex = index + 1
            guard valueIndex < arguments.count else {
                throw BridgeFailure("missing_expected_range", "--expected-range-length requires a value.")
            }
            guard expectedRangeLength == nil else {
                throw BridgeFailure("duplicate_expected_range", "--expected-range-length may be specified only once.")
            }
            guard let parsed = Int(arguments[valueIndex]), parsed > 0 else {
                throw BridgeFailure("invalid_expected_range", "--expected-range-length must be a positive integer.")
            }
            expectedRangeLength = parsed
            index += 2
        case "--help", "-h":
            return nil
        default:
            throw BridgeFailure(
                "unexpected_argument",
                "Unexpected command-line argument.",
                details: ["received": arguments[index]]
            )
        }
    }

    var replacement: String?
    if targetFromStandardInput {
        target = try readTargetFromStandardInput()
    }
    if editFromStandardInput {
        let edit = try readEditFromStandardInput()
        target = edit.target
        replacement = edit.replacement
    }
    guard let target else {
        throw BridgeFailure("missing_target", "A non-empty --target or --target-stdin value is required.")
    }
    guard !target.isEmpty else {
        throw BridgeFailure("empty_target", "The target must not be empty.")
    }
    if command == .replace {
        guard editFromStandardInput else {
            throw BridgeFailure("missing_replacement", "Replace requires the target and replacement over --edit-stdin.")
        }
        guard let replacement, !replacement.isEmpty else {
            throw BridgeFailure("empty_replacement", "The replacement must not be empty; use delete to remove text.")
        }
    }

    let suppliedPreconditionFieldCount = [
        expectedValueSHA256 != nil,
        expectedProcessIdentifier != nil,
        expectedRangeLocation != nil,
        expectedRangeLength != nil,
    ].filter { $0 }.count

    let deletePrecondition: DeletePrecondition?
    switch command {
    case .inspect:
        guard suppliedPreconditionFieldCount == 0 else {
            throw BridgeFailure(
                "unexpected_delete_precondition",
                "Delete precondition arguments are valid only with the delete or replace command."
            )
        }
        deletePrecondition = nil
    case .delete, .replace:
        guard suppliedPreconditionFieldCount == 4,
              let expectedValueSHA256,
              let expectedProcessIdentifier,
              let expectedRangeLocation,
              let expectedRangeLength else {
            throw BridgeFailure(
                "missing_delete_precondition",
                "This command requires the digest, process ID, and UTF-16 range returned by inspect."
            )
        }
        deletePrecondition = DeletePrecondition(
            valueSHA256: expectedValueSHA256,
            processIdentifier: expectedProcessIdentifier,
            range: NSRange(location: expectedRangeLocation, length: expectedRangeLength)
        )
    }

    return CLIOptions(
        command: command,
        target: target,
        bundleIdentifier: bundleIdentifier,
        deletePrecondition: deletePrecondition,
        replacement: replacement
    )
}

private func readEditFromStandardInput() throws -> (target: String, replacement: String) {
    let data: Data
    do {
        data = try FileHandle.standardInput.read(upToCount: maximumEditStdinByteCount + 1) ?? Data()
    } catch {
        throw BridgeFailure("edit_stdin_unavailable", "Could not read the edit from standard input.")
    }
    switch parseEditStdin(data) {
    case .success(let edit):
        return edit
    case .failure(.tooLarge):
        throw BridgeFailure("edit_too_large", "The standard-input edit is too large.")
    case .failure(.missingSeparator):
        throw BridgeFailure(
            "invalid_edit_framing",
            "Replace stdin must be the target, a single NUL byte, then the replacement."
        )
    case .failure(.invalidEncoding):
        throw BridgeFailure(
            "invalid_edit_encoding",
            "The target and replacement must be UTF-8 text separated by exactly one NUL byte."
        )
    }
}

private func readTargetFromStandardInput() throws -> String {
    let maximumTargetBytes = 64 * 1_024
    let data: Data
    do {
        data = try FileHandle.standardInput.read(upToCount: maximumTargetBytes + 1) ?? Data()
    } catch {
        throw BridgeFailure("target_stdin_unavailable", "Could not read the target from standard input.")
    }
    guard data.count <= maximumTargetBytes else {
        throw BridgeFailure("target_too_large", "The standard-input target is too large.")
    }
    guard !data.contains(0), let value = String(data: data, encoding: .utf8) else {
        throw BridgeFailure("invalid_target_encoding", "The standard-input target must be UTF-8 text without NUL bytes.")
    }
    return value
}

private func inspectFocusedElement(target: String, bundleIdentifier: String?) throws -> Inspection {
    guard AXIsProcessTrusted() else {
        throw BridgeFailure(
            "accessibility_permission_required",
            "Accessibility permission is required. Grant it manually, then run the command again."
        )
    }

    let focusedRef: CFTypeRef
    var requestedProcessIdentifier: pid_t?
    if let bundleIdentifier {
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { !$0.isTerminated }
        guard !applications.isEmpty else {
            throw BridgeFailure(
                "target_app_not_running",
                "No running app matches the requested bundle identifier.",
                details: ["bundleIdentifier": bundleIdentifier]
            )
        }

        let application: NSRunningApplication
        if applications.count == 1 {
            application = applications[0]
        } else if let active = applications.first(where: \.isActive) {
            application = active
        } else {
            throw BridgeFailure(
                "ambiguous_target_app",
                "More than one app process matches the bundle identifier and none is active.",
                details: ["bundleIdentifier": bundleIdentifier, "processCount": applications.count]
            )
        }

        requestedProcessIdentifier = application.processIdentifier
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var appFocusedRef: CFTypeRef?
        let focusError = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &appFocusedRef
        )
        guard focusError == .success, let appFocusedRef else {
            throw BridgeFailure(
                "app_focused_element_unavailable",
                "The target app did not expose a focused UI element. Make it frontmost, focus its editable field, and retry.",
                details: ["bundleIdentifier": bundleIdentifier, "axError": focusError.rawValue]
            )
        }
        focusedRef = appFocusedRef
    } else {
        let systemWide = AXUIElementCreateSystemWide()
        focusedRef = try copyAttribute(
            from: systemWide,
            attribute: kAXFocusedUIElementAttribute,
            errorCode: "focused_element_unavailable"
        )
    }
    guard CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
        throw BridgeFailure("focused_element_unavailable", "The focused accessibility object is not a UI element.")
    }
    let element = unsafeDowncast(focusedRef, to: AXUIElement.self)
    var processIdentifier: pid_t = 0
    let pidError = AXUIElementGetPid(element, &processIdentifier)
    guard pidError == .success, processIdentifier > 0 else {
        throw BridgeFailure(
            "focused_process_unavailable",
            "Could not determine the focused element's process ID.",
            details: ["axError": pidError.rawValue]
        )
    }
    if let requestedProcessIdentifier, requestedProcessIdentifier != processIdentifier {
        throw BridgeFailure(
            "focused_process_mismatch",
            "The focused accessibility element does not belong to the requested app process.",
            details: [
                "requestedProcessIdentifier": requestedProcessIdentifier,
                "actualProcessIdentifier": processIdentifier,
            ]
        )
    }

    let expectedProcessIdentifier = requestedProcessIdentifier ?? processIdentifier

    // Establish the privacy boundary once after resolving the AX element, then
    // deliberately sample it again as the final operation before AXValue. This
    // closes background-app and secure-field reads even if focus or metadata
    // changes while editability support is being checked.
    try assertFocusedValueReadAllowed(
        from: element,
        expectedProcessIdentifier: expectedProcessIdentifier
    )

    let editable = isAttributeSettable(element, kAXValueAttribute)
        || isAttributeSettable(element, kAXSelectedTextAttribute)
        || isAttributeSettable(element, kAXSelectedTextRangeAttribute)
    guard editable else {
        throw BridgeFailure("focused_element_not_editable", "The focused text element is not editable.")
    }

    let value = try readTextValue(
        from: element,
        expectedProcessIdentifier: expectedProcessIdentifier
    )

    let ranges = exactRanges(of: target, in: value)
    guard !ranges.isEmpty else {
        throw BridgeFailure(
            "target_not_found",
            "The exact target text was not found in the focused element.",
            details: ["target": target]
        )
    }

    let selectedRange = copyRangeAttribute(from: element, attribute: kAXSelectedTextRangeAttribute)
    let chosenRange: NSRange
    if ranges.count == 1 {
        chosenRange = ranges[0]
    } else if let selectedRange, ranges.contains(where: { NSEqualRanges($0, selectedRange) }) {
        chosenRange = selectedRange
    } else {
        throw BridgeFailure(
            "ambiguous_target",
            "The target occurs more than once. Select the intended occurrence exactly and retry.",
            details: ["occurrenceCount": ranges.count, "target": target]
        )
    }

    return Inspection(
        element: element,
        value: value,
        target: target,
        range: chosenRange,
        occurrenceCount: ranges.count,
        elementFrame: copyElementFrame(element),
        targetBounds: copyBounds(for: chosenRange, from: element),
        requestedBundleIdentifier: bundleIdentifier,
        processIdentifier: processIdentifier
    )
}

/// Validates both the exact process scope and security metadata without reading
/// kAXValue. Target scope is checked before metadata and once more afterward so
/// a background transition during the metadata reads also fails closed.
private func assertFocusedValueReadAllowed(
    from element: AXUIElement,
    expectedProcessIdentifier: pid_t
) throws {
    try assertFocusedValueTarget(
        element,
        expectedProcessIdentifier: expectedProcessIdentifier
    )

    let roleRead = readSecurityMetadata(
        from: element,
        attribute: kAXRoleAttribute,
        securityAttribute: .role
    )

    // A secure role is conclusive. Do not query more metadata from it.
    if focusedValueSecurityDecision(
        role: roleRead.policyValue,
        subrole: .unavailable
    ) == .secure {
        throw secureFocusedElementFailure(role: roleRead.stringValue, subrole: nil)
    }
    guard case .value = roleRead else {
        throw securityMetadataUnavailableFailure(attribute: .role, read: roleRead)
    }

    let subroleRead = readSecurityMetadata(
        from: element,
        attribute: kAXSubroleAttribute,
        securityAttribute: .subrole
    )
    switch focusedValueSecurityDecision(
        role: roleRead.policyValue,
        subrole: subroleRead.policyValue
    ) {
    case .allow:
        break
    case .secure:
        throw secureFocusedElementFailure(
            role: roleRead.stringValue,
            subrole: subroleRead.stringValue
        )
    case .deny(let unavailableAttribute):
        throw securityMetadataUnavailableFailure(
            attribute: unavailableAttribute,
            read: unavailableAttribute == .role ? roleRead : subroleRead
        )
    }

    try assertFocusedValueTarget(
        element,
        expectedProcessIdentifier: expectedProcessIdentifier
    )
}

private func assertFocusedValueTarget(
    _ element: AXUIElement,
    expectedProcessIdentifier: pid_t
) throws {
    var actualProcessIdentifier: pid_t = 0
    let pidError = AXUIElementGetPid(element, &actualProcessIdentifier)
    guard pidError == .success, actualProcessIdentifier > 0 else {
        throw BridgeFailure(
            "focused_process_unavailable",
            "Could not determine the focused element's process ID.",
            details: ["axError": pidError.rawValue]
        )
    }

    let application = NSRunningApplication(processIdentifier: expectedProcessIdentifier)
    switch focusedValueTargetDecision(
        expectedProcessIdentifier: expectedProcessIdentifier,
        actualProcessIdentifier: actualProcessIdentifier,
        frontmostProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier,
        targetApplicationIsActive: application?.isActive == true
    ) {
    case .allow:
        break
    case .processIdentifierMismatch:
        throw BridgeFailure(
            "focused_process_mismatch",
            "The focused accessibility element does not belong to the requested app process.",
            details: [
                "requestedProcessIdentifier": expectedProcessIdentifier,
                "actualProcessIdentifier": actualProcessIdentifier,
            ]
        )
    case .targetApplicationNotFrontmost:
        throw targetAppNotFrontmostFailure(expectedProcessIdentifier)
    }

    // A retained AX object can remain valid after focus moves to another field
    // in the same process. Re-read app focus and require this exact object before
    // allowing its value to be read or changed.
    let appElement = AXUIElementCreateApplication(expectedProcessIdentifier)
    var focusedRef: CFTypeRef?
    let focusError = AXUIElementCopyAttributeValue(
        appElement,
        kAXFocusedUIElementAttribute as CFString,
        &focusedRef
    )
    guard focusError == .success, let focusedRef else {
        throw BridgeFailure(
            "app_focused_element_unavailable",
            "The target app did not expose its current focused UI element.",
            details: [
                "expectedProcessIdentifier": expectedProcessIdentifier,
                "axError": focusError.rawValue,
            ]
        )
    }
    guard CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
        throw BridgeFailure(
            "focused_element_unavailable",
            "The target app's focused accessibility object is not a UI element."
        )
    }
    guard CFEqual(focusedRef, element) else {
        throw BridgeFailure(
            "focused_element_unavailable",
            "The inspected accessibility element is no longer the target app's focused element.",
            details: ["expectedProcessIdentifier": expectedProcessIdentifier]
        )
    }
}

private func readSecurityMetadata(
    from element: AXUIElement,
    attribute: String,
    securityAttribute: FocusedValueSecurityAttribute
) -> AXSecurityMetadataRead {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    switch focusedValueSecurityMetadataReadStatus(error: error, attribute: securityAttribute) {
    case .absent:
        return .absent
    case .unavailable:
        return .unavailable(axError: error, reason: "ax_error")
    case .success:
        break
    }
    guard let value else {
        return .unavailable(axError: nil, reason: "missing_value")
    }
    guard let string = value as? String, !string.isEmpty else {
        return .unavailable(axError: nil, reason: "value_not_string")
    }
    return .value(string)
}

private func secureFocusedElementFailure(role: String?, subrole: String?) -> BridgeFailure {
    BridgeFailure(
        "secure_field_ignored",
        "The focused accessibility element is a secure text field. Its value was not read.",
        details: [
            "role": role ?? NSNull(),
            "subrole": subrole ?? NSNull(),
        ]
    )
}

private func securityMetadataUnavailableFailure(
    attribute: FocusedValueSecurityAttribute,
    read: AXSecurityMetadataRead
) -> BridgeFailure {
    var details: [String: Any] = ["attribute": attribute.rawValue]
    if case .unavailable(let axError, let reason) = read {
        details["metadataError"] = reason
        if let axError {
            details["axError"] = axError.rawValue
        }
    }
    return BridgeFailure(
        "security_metadata_unavailable",
        "The focused element's security metadata could not be verified. Its value was not read.",
        details: details
    )
}

private func inspectionPayload(_ inspection: Inspection, command: Command) -> [String: Any] {
    var payload: [String: Any] = [
        "command": command.rawValue,
        "target": inspection.target,
        "valueSHA256": sha256UTF8(inspection.value),
        "targetProcessIdentifier": inspection.processIdentifier,
        "utf16Range": rangeDictionary(inspection.range),
        "occurrenceCount": inspection.occurrenceCount,
        "focusedElementFrame": inspection.elementFrame.map(rectDictionary) ?? NSNull(),
        "targetBounds": inspection.targetBounds.map(rectDictionary) ?? NSNull(),
        "targetBoundsAvailable": inspection.targetBounds != nil,
        "deleted": false,
    ]
    if command == .inspect {
        // Inspection still needs the value for fallback geometry and expected-
        // remainder calculation. Delete responses expose only value digests in
        // their precondition result.
        payload["currentValue"] = inspection.value
    }
    payload["bundleIdentifier"] = inspection.requestedBundleIdentifier ?? NSNull()
    return payload
}

private func applyExactEdit(
    from inspection: Inspection,
    precondition: DeletePrecondition,
    replacement: String
) throws -> (method: String, value: String) {
    // Validate the separate inspect process's digest, PID, and exact range before
    // touching accessibility state. The live check is repeated at every write.
    try assertDeletePrecondition(
        precondition,
        inspection: inspection,
        liveValue: inspection.value
    )

    let source = inspection.value as NSString
    let expected = source.replacingCharacters(in: precondition.range, with: replacement)
    // Bound the POST-edit value before any write. A replacement can grow the
    // value past the 64 KiB ceiling that pre-write reads only apply to the
    // current value, so reject oversize edits here rather than mutating the
    // live field and only failing on read-back (which would break the
    // all-or-nothing write contract). Deletes can only shrink, so never trip.
    if case .deny(let exceededEncoding) = focusedValueSizeDecision(expected) {
        throw BridgeFailure(
            "focused_value_too_large",
            "The post-edit value would exceed the 64 KiB encoded-size safety limit; no write was attempted.",
            details: [
                "exceededEncoding": exceededEncoding.rawValue,
                "maximumEncodedBytes": maximumFocusedValueEncodedByteCount,
            ]
        )
    }
    var selectionError: AXError?
    var selectedTextError: AXError?

    if let rangeValue = makeAXRange(precondition.range),
       isAttributeSettable(inspection.element, kAXSelectedTextRangeAttribute),
       isAttributeSettable(inspection.element, kAXSelectedTextAttribute) {
        let liveValue = try readTextValue(
            from: inspection.element,
            expectedProcessIdentifier: precondition.processIdentifier
        )
        try assertDeletePrecondition(
            precondition,
            inspection: inspection,
            liveValue: liveValue
        )
        selectionError = AXUIElementSetAttributeValue(
            inspection.element,
            kAXSelectedTextRangeAttribute as CFString,
            rangeValue
        )

        if selectionError == .success,
           copyRangeAttribute(from: inspection.element, attribute: kAXSelectedTextRangeAttribute)
              .map({ NSEqualRanges($0, precondition.range) }) == true {
            let selectedLiveValue = try readTextValue(
                from: inspection.element,
                expectedProcessIdentifier: precondition.processIdentifier
            )
            try assertDeletePrecondition(
                precondition,
                inspection: inspection,
                liveValue: selectedLiveValue
            )
            selectedTextError = AXUIElementSetAttributeValue(
                inspection.element,
                kAXSelectedTextAttribute as CFString,
                replacement as CFString
            )

            if selectedTextError == .success {
                if try waitForExpectedTextValue(
                    from: inspection.element,
                    expected: expected,
                    allowedPendingValue: selectedLiveValue,
                    expectedProcessIdentifier: precondition.processIdentifier
                ) {
                    return ("selectedText", expected)
                }

                // A successful AX write can still be applied asynchronously. Do
                // not race it with a whole-value fallback after the retry window.
                throw BridgeFailure(
                    "delete_verification_timed_out",
                    "The selected-text write was accepted but did not become observable within 240 ms. No fallback was attempted."
                )
            }
        }
    }

    let current = try readTextValue(
        from: inspection.element,
        expectedProcessIdentifier: precondition.processIdentifier
    )
    try assertDeletePrecondition(
        precondition,
        inspection: inspection,
        liveValue: current
    )
    guard isAttributeSettable(inspection.element, kAXValueAttribute) else {
        var details: [String: Any] = [:]
        if let selectionError {
            details["selectionAXError"] = selectionError.rawValue
        }
        if let selectedTextError {
            details["selectedTextAXError"] = selectedTextError.rawValue
        }
        throw BridgeFailure(
            "delete_not_supported",
            "The focused element supports neither selected-text replacement nor setting its whole value.",
            details: details
        )
    }

    // The settable query above is non-mutating, but focus can change between any
    // two calls. Recheck immediately before the whole-value write.
    try assertDeletePrecondition(
        precondition,
        inspection: inspection,
        liveValue: try readTextValue(
            from: inspection.element,
            expectedProcessIdentifier: precondition.processIdentifier
        )
    )
    let setError = AXUIElementSetAttributeValue(
        inspection.element,
        kAXValueAttribute as CFString,
        expected as CFString
    )
    guard setError == .success else {
        throw BridgeFailure(
            "delete_failed",
            "Setting the replacement value failed.",
            details: ["axError": setError.rawValue]
        )
    }

    guard try waitForExpectedTextValue(
        from: inspection.element,
        expected: expected,
        allowedPendingValue: current,
        expectedProcessIdentifier: precondition.processIdentifier
    ) else {
        throw BridgeFailure(
            "delete_verification_timed_out",
            "The whole-value write was accepted but did not become observable within 240 ms."
        )
    }
    return ("wholeValueFallback", expected)
}

private func assertDeletePrecondition(
    _ expected: DeletePrecondition,
    inspection: Inspection,
    liveValue: String
) throws {
    var liveProcessIdentifier: pid_t = 0
    let pidError = AXUIElementGetPid(inspection.element, &liveProcessIdentifier)
    guard pidError == .success, liveProcessIdentifier > 0 else {
        throw BridgeFailure(
            "focused_process_unavailable",
            "Could not re-read the focused element's process ID. Nothing was deleted.",
            details: ["axError": pidError.rawValue]
        )
    }

    let application = NSRunningApplication(processIdentifier: expected.processIdentifier)
    let snapshot = DeletePreconditionSnapshot(
        value: liveValue,
        target: inspection.target,
        range: inspection.range,
        processIdentifier: liveProcessIdentifier,
        frontmostProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier,
        targetApplicationIsActive: application?.isActive == true
    )

    do {
        try validateDeletePrecondition(expected, against: snapshot)
    } catch DeletePreconditionViolation.valueDigestMismatch {
        throw BridgeFailure(
            "value_digest_mismatch",
            "The full focused value changed after inspection. Nothing was deleted.",
            details: [
                "expectedSHA256": expected.valueSHA256,
                "actualSHA256": sha256UTF8(liveValue),
            ]
        )
    } catch DeletePreconditionViolation.processIdentifierMismatch {
        throw BridgeFailure(
            "target_process_changed",
            "The focused element no longer belongs to the inspected app process. Nothing was deleted.",
            details: [
                "expectedProcessIdentifier": expected.processIdentifier,
                "actualProcessIdentifier": liveProcessIdentifier,
            ]
        )
    } catch DeletePreconditionViolation.rangeMismatch {
        throw BridgeFailure(
            "target_range_mismatch",
            "The inspected UTF-16 range no longer identifies the exact target. Nothing was deleted.",
            details: [
                "expectedRange": rangeDictionary(expected.range),
                "actualRange": rangeDictionary(inspection.range),
            ]
        )
    } catch DeletePreconditionViolation.targetApplicationNotFrontmost {
        throw targetAppNotFrontmostFailure(expected.processIdentifier)
    }

    // Snapshot validation above checks the content invariants. Re-run the full
    // privacy/focus gate as the final operation before returning to an AX write,
    // including exact focused-element identity within the same app process.
    try assertFocusedValueReadAllowed(
        from: inspection.element,
        expectedProcessIdentifier: expected.processIdentifier
    )
}

private func targetAppNotFrontmostFailure(_ expectedProcessIdentifier: pid_t) -> BridgeFailure {
    let frontmostProcessIdentifier: Any = NSWorkspace.shared.frontmostApplication
        .map { Int($0.processIdentifier) } ?? NSNull()
    return BridgeFailure(
        "target_app_not_frontmost",
        "The inspected app process is no longer active and frontmost. Nothing was deleted.",
        details: [
            "expectedProcessIdentifier": expectedProcessIdentifier,
            "frontmostProcessIdentifier": frontmostProcessIdentifier,
        ]
    )
}

/// Polls an eventually-consistent AX value without accepting any third state.
/// The initial read is immediate, followed by at most six 40 ms retries.
private func waitForExpectedTextValue(
    from element: AXUIElement,
    expected: String,
    allowedPendingValue: String,
    expectedProcessIdentifier: pid_t,
    retryCount: Int = 6,
    retryDelayMicroseconds: useconds_t = 40_000
) throws -> Bool {
    for attempt in 0...retryCount {
        if attempt > 0 {
            usleep(retryDelayMicroseconds)
        }

        let actual = try readTextValue(
            from: element,
            expectedProcessIdentifier: expectedProcessIdentifier
        )
        if actual == expected {
            return true
        }
        guard actual == allowedPendingValue else {
            throw BridgeFailure(
                "unexpected_value_change",
                "The focused value changed unexpectedly during write verification. No further write was attempted."
            )
        }
    }
    return false
}

private func copyAttribute(
    from element: AXUIElement,
    attribute: String,
    errorCode: String
) throws -> CFTypeRef {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    guard error == .success, let value else {
        throw BridgeFailure(
            errorCode,
            "Could not read accessibility attribute '\(attribute)'.",
            details: ["axError": error.rawValue]
        )
    }
    return value
}

private func readTextValue(
    from element: AXUIElement,
    expectedProcessIdentifier: pid_t
) throws -> String {
    try assertFocusedValueReadAllowed(
        from: element,
        expectedProcessIdentifier: expectedProcessIdentifier
    )
    let ref = try copyAttribute(
        from: element,
        attribute: kAXValueAttribute,
        errorCode: "focused_value_unavailable"
    )
    let value: String
    if let string = ref as? String {
        value = string
    } else if let attributed = ref as? NSAttributedString {
        value = attributed.string
    } else {
        throw BridgeFailure(
            "focused_value_not_text",
            "The focused UI element does not expose a textual accessibility value."
        )
    }

    switch focusedValueSizeDecision(value) {
    case .allow:
        return value
    case .deny(let exceededEncoding):
        throw BridgeFailure(
            "focused_value_too_large",
            "The focused textual accessibility value exceeds the 64 KiB encoded-size safety limit.",
            details: [
                "exceededEncoding": exceededEncoding.rawValue,
                "maximumEncodedBytes": maximumFocusedValueEncodedByteCount,
            ]
        )
    }
}

private func isAttributeSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
    var settable = DarwinBoolean(false)
    let error = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
    return error == .success && settable.boolValue
}

private func exactRanges(of target: String, in value: String) -> [NSRange] {
    let source = value as NSString
    var ranges: [NSRange] = []
    var searchStart = 0

    while searchStart <= source.length {
        let searchRange = NSRange(location: searchStart, length: source.length - searchStart)
        let found = source.range(of: target, options: [], range: searchRange)
        if found.location == NSNotFound {
            break
        }
        ranges.append(found)
        // Advance one UTF-16 code unit so overlapping matches are also treated as
        // ambiguous. The target is non-empty, so this always makes progress.
        searchStart = found.location + 1
    }

    return ranges
}

private func makeAXRange(_ range: NSRange) -> AXValue? {
    var cfRange = CFRange(location: range.location, length: range.length)
    return AXValueCreate(.cfRange, &cfRange)
}

private func copyRangeAttribute(from element: AXUIElement, attribute: String) -> NSRange? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
          let ref,
          CFGetTypeID(ref) == AXValueGetTypeID() else {
        return nil
    }
    let value = unsafeDowncast(ref, to: AXValue.self)
    guard AXValueGetType(value) == .cfRange else {
        return nil
    }
    var range = CFRange()
    guard AXValueGetValue(value, .cfRange, &range) else {
        return nil
    }
    return NSRange(location: range.location, length: range.length)
}

private func copyElementFrame(_ element: AXUIElement) -> CGRect? {
    var positionRef: CFTypeRef?
    var sizeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
          AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
          let positionRef,
          let sizeRef,
          CFGetTypeID(positionRef) == AXValueGetTypeID(),
          CFGetTypeID(sizeRef) == AXValueGetTypeID() else {
        return nil
    }

    let positionValue = unsafeDowncast(positionRef, to: AXValue.self)
    let sizeValue = unsafeDowncast(sizeRef, to: AXValue.self)
    var position = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetType(positionValue) == .cgPoint,
          AXValueGetType(sizeValue) == .cgSize,
          AXValueGetValue(positionValue, .cgPoint, &position),
          AXValueGetValue(sizeValue, .cgSize, &size) else {
        return nil
    }
    return CGRect(origin: position, size: size)
}

private func copyBounds(for range: NSRange, from element: AXUIElement) -> CGRect? {
    guard let rangeValue = makeAXRange(range) else {
        return nil
    }
    var boundsRef: CFTypeRef?
    let error = AXUIElementCopyParameterizedAttributeValue(
        element,
        kAXBoundsForRangeParameterizedAttribute as CFString,
        rangeValue,
        &boundsRef
    )
    guard error == .success,
          let boundsRef,
          CFGetTypeID(boundsRef) == AXValueGetTypeID() else {
        return nil
    }

    let boundsValue = unsafeDowncast(boundsRef, to: AXValue.self)
    var bounds = CGRect.zero
    guard AXValueGetType(boundsValue) == .cgRect,
          AXValueGetValue(boundsValue, .cgRect, &bounds),
          bounds.origin.x.isFinite,
          bounds.origin.y.isFinite,
          bounds.size.width.isFinite,
          bounds.size.height.isFinite,
          bounds.size.width > 0,
          bounds.size.height > 0 else {
        return nil
    }
    return bounds
}

private func rangeDictionary(_ range: NSRange) -> [String: Any] {
    ["location": range.location, "length": range.length]
}

private func rectDictionary(_ rect: CGRect) -> [String: Any] {
    [
        "x": Double(rect.origin.x),
        "y": Double(rect.origin.y),
        "width": Double(rect.size.width),
        "height": Double(rect.size.height),
    ]
}

private func writeJSON(_ payload: [String: Any]) {
    do {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    } catch {
        let fallback = "{\"ok\":false,\"error\":{\"code\":\"json_encoding_failed\"}}\n"
        FileHandle.standardOutput.write(Data(fallback.utf8))
    }
}
