public struct SensorCLIParseFailure: Error, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct SensorCLIOptions: Equatable, Sendable {
    public let bundleIdentifier: String
    public let durationMilliseconds: Double?
    public let mouseWindowMilliseconds: Double
    public let emitText: Bool
    public let textOnly: Bool

    public init(
        bundleIdentifier: String,
        durationMilliseconds: Double?,
        mouseWindowMilliseconds: Double,
        emitText: Bool,
        textOnly: Bool
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.durationMilliseconds = durationMilliseconds
        self.mouseWindowMilliseconds = mouseWindowMilliseconds
        self.emitText = emitText
        self.textOnly = textOnly
    }

    public static let help = """
    Usage:
      wds-sensor --bundle-id <id> [--duration-ms <milliseconds>] [--mouse-window-ms <milliseconds>] [--emit-text] [--text-only]

    Observes only the focused, editable, non-secure text element in the specified
    running app. Redacted text snapshots and bounded mouse-activity summaries are
    written as JSON Lines to stdout. Mouse samples remain in memory and are never
    emitted raw.

    Options:
      --bundle-id <id>          Required target application bundle identifier.
      --duration-ms <n>         Stop after n milliseconds. Omit to run until interrupted.
      --mouse-window-ms <n>     Recent mouse-summary window (default: 2000).
      --emit-text               Include raw focused text in snapshots. Default: redacted.
      --text-only               Disable mouse capture and Input Monitoring use entirely.
      -h, --help                Show this help.

    Permissions are checked without opening System Settings or prompting. This tool
    never installs a keyboard event tap, mutates text, submits text, or writes data
    to disk. --text-only never checks Input Monitoring or creates a mouse event tap.
    """

    public static func parse(_ arguments: [String]) throws -> SensorCLIOptions? {
        if arguments == ["--help"] || arguments == ["-h"] {
            return nil
        }

        var bundleIdentifier: String?
        var durationMilliseconds: Double?
        var mouseWindowMilliseconds = 2_000.0
        var hasMouseWindow = false
        var emitText = false
        var textOnly = false
        var index = 0

        while index < arguments.count {
            let flag = arguments[index]
            if flag == "--emit-text" {
                guard !emitText else {
                    throw SensorCLIParseFailure(
                        code: "duplicate_emit_text",
                        message: "--emit-text may be specified only once."
                    )
                }
                emitText = true
                index += 1
                continue
            }
            if flag == "--text-only" {
                guard !textOnly else {
                    throw SensorCLIParseFailure(
                        code: "duplicate_text_only",
                        message: "--text-only may be specified only once."
                    )
                }
                textOnly = true
                index += 1
                continue
            }
            guard index + 1 < arguments.count else {
                throw SensorCLIParseFailure(
                    code: "missing_argument_value",
                    message: "A command-line option requires a value."
                )
            }
            let value = arguments[index + 1]

            switch flag {
            case "--bundle-id":
                guard bundleIdentifier == nil else {
                    throw SensorCLIParseFailure(
                        code: "duplicate_bundle_id",
                        message: "--bundle-id may be specified only once."
                    )
                }
                guard !value.isEmpty else {
                    throw SensorCLIParseFailure(
                        code: "empty_bundle_id",
                        message: "The bundle identifier must not be empty."
                    )
                }
                bundleIdentifier = value
            case "--duration-ms":
                guard durationMilliseconds == nil else {
                    throw SensorCLIParseFailure(
                        code: "duplicate_duration",
                        message: "--duration-ms may be specified only once."
                    )
                }
                guard let parsed = Double(value), parsed.isFinite, parsed >= 100 else {
                    throw SensorCLIParseFailure(
                        code: "invalid_duration",
                        message: "--duration-ms must be a finite number of at least 100."
                    )
                }
                durationMilliseconds = parsed
            case "--mouse-window-ms":
                guard !hasMouseWindow else {
                    throw SensorCLIParseFailure(
                        code: "duplicate_mouse_window",
                        message: "--mouse-window-ms may be specified only once."
                    )
                }
                guard let parsed = Double(value), parsed.isFinite, parsed >= 100, parsed <= 60_000 else {
                    throw SensorCLIParseFailure(
                        code: "invalid_mouse_window",
                        message: "--mouse-window-ms must be between 100 and 60000."
                    )
                }
                mouseWindowMilliseconds = parsed
                hasMouseWindow = true
            default:
                throw SensorCLIParseFailure(
                    code: "unexpected_argument",
                    message: "Unexpected command-line argument."
                )
            }
            index += 2
        }

        guard let bundleIdentifier else {
            throw SensorCLIParseFailure(
                code: "missing_bundle_id",
                message: "--bundle-id is required."
            )
        }
        return SensorCLIOptions(
            bundleIdentifier: bundleIdentifier,
            durationMilliseconds: durationMilliseconds,
            mouseWindowMilliseconds: mouseWindowMilliseconds,
            emitText: emitText,
            textOnly: textOnly
        )
    }
}

public struct SensorRuntimePlan: Equatable, Sendable {
    public let usesMouseCapture: Bool
    public let requiresInputMonitoringPermission: Bool
    public let emitsMouseSummaries: Bool
    public let mouseOutputAttestation: String

    public init(textOnly: Bool) {
        usesMouseCapture = !textOnly
        requiresInputMonitoringPermission = !textOnly
        emitsMouseSummaries = !textOnly
        mouseOutputAttestation = textOnly ? "disabled" : "derived_summary_only"
    }
}

public struct SensorTextDisclosurePlan: Equatable, Sendable {
    public let readsAccessibilityValue: Bool
    public let includesRawText: Bool
    public let includesUTF16Length: Bool
    public let textRedacted: Bool

    public init(emitText: Bool) {
        readsAccessibilityValue = emitText
        includesRawText = emitText
        includesUTF16Length = emitText
        textRedacted = !emitText
    }
}
