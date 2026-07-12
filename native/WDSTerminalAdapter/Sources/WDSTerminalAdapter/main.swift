import Foundation
import WDSTerminalAdapterCore

private struct ResolveOptions {
    let surface: TerminalSurface
    let cursorUnicodeScalarOffset: Int
    let socketPath: String
    let timeoutMilliseconds: Int32
    let authenticationToken: String
}

struct WDSTerminalAdapterCommand {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--help"] || arguments == ["-h"] {
            FileHandle.standardOutput.write(Data(help.utf8))
            return
        }

        guard let options = parseResolveOptions(arguments) else {
            writePassThrough()
            return
        }

        do {
            guard let input = try readBoundedStandardInput() else {
                writePassThrough()
                return
            }
            guard let buffer = String(data: input, encoding: .utf8) else {
                writePassThrough()
                return
            }
            let snapshot = try TerminalBufferSnapshot(
                buffer: buffer,
                cursorUnicodeScalarOffset: options.cursorUnicodeScalarOffset
            )
            let request = TerminalResolveRequest(
                requestID: UUID().uuidString.lowercased(),
                surface: options.surface,
                snapshot: snapshot
            )
            let response = try UnixSocketCallbackClient(
                path: options.socketPath,
                timeoutMilliseconds: options.timeoutMilliseconds,
                authenticationToken: options.authenticationToken
            ).resolve(request)

            switch try resolveTerminalResponse(response, for: request) {
            case .passThrough:
                writePassThrough()
            case let .applied(edit):
                writeApplied(edit)
            }
        } catch {
            // Deliberately silent and fail-closed. The caller receives an unchanged
            // pass-through decision; buffer contents and errors are never logged.
            writePassThrough()
        }
    }

    private static func parseResolveOptions(_ arguments: [String]) -> ResolveOptions? {
        guard arguments.first == "resolve" else { return nil }

        var surface: TerminalSurface?
        var surfaceIdentifier: String?
        var cursor: Int?
        var socketPath: String?
        var timeout = 15_000
        var index = 1

        while index < arguments.count {
            guard index + 1 < arguments.count else { return nil }
            let flag = arguments[index]
            let value = arguments[index + 1]
            switch flag {
            case "--surface":
                switch value {
                case "zsh-zle":
                    surface = TerminalSurface(kind: .zshZLE)
                case "interactive-cli":
                    surface = TerminalSurface(kind: .interactiveCLI)
                default:
                    return nil
                }
            case "--surface-id":
                surfaceIdentifier = value
            case "--cursor-scalar-offset":
                cursor = Int(value)
            case "--socket":
                socketPath = value
            case "--timeout-ms":
                guard let parsed = Int(value), (10...60_000).contains(parsed) else {
                    return nil
                }
                timeout = parsed
            default:
                return nil
            }
            index += 2
        }

        guard var resolvedSurface = surface, let cursor else { return nil }
        if resolvedSurface.kind == .interactiveCLI {
            guard let surfaceIdentifier,
                  isValidSurfaceIdentifier(surfaceIdentifier) else {
                return nil
            }
            resolvedSurface = TerminalSurface(
                kind: .interactiveCLI,
                identifier: surfaceIdentifier
            )
        } else if surfaceIdentifier != nil {
            return nil
        }

        let environment = ProcessInfo.processInfo.environment
        let resolvedSocketPath = socketPath
            ?? environment["WDS_TERMINAL_SOCKET"]
            ?? defaultSocketPath()
        guard let authenticationToken = environment["WDS_TERMINAL_AUTH_TOKEN"],
              isValidTerminalAuthenticationToken(authenticationToken) else {
            return nil
        }
        return ResolveOptions(
            surface: resolvedSurface,
            cursorUnicodeScalarOffset: cursor,
            socketPath: resolvedSocketPath,
            timeoutMilliseconds: Int32(timeout),
            authenticationToken: authenticationToken
        )
    }

    private static func defaultSocketPath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/WDS", isDirectory: true)
            .appendingPathComponent("terminal.sock", isDirectory: false)
            .path
    }

    private static func isValidSurfaceIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        return value.unicodeScalars.allSatisfy {
            ($0.value >= 0x30 && $0.value <= 0x39)
                || ($0.value >= 0x41 && $0.value <= 0x5a)
                || ($0.value >= 0x61 && $0.value <= 0x7a)
                || $0 == "." || $0 == "_" || $0 == "-"
        }
    }

    private static func writePassThrough() {
        FileHandle.standardOutput.write(Data("pass\n".utf8))
    }

    private static func readBoundedStandardInput() throws -> Data? {
        var input = Data()
        while input.count <= wdsMaximumTerminalBufferBytes {
            let remaining = wdsMaximumTerminalBufferBytes + 1 - input.count
            guard let chunk = try FileHandle.standardInput.read(
                upToCount: min(64 * 1_024, remaining)
            ), !chunk.isEmpty else {
                return input
            }
            input.append(chunk)
        }
        return nil
    }

    private static func writeApplied(_ edit: AppliedTerminalDeletion) {
        var output = Data("replace\n\(edit.cursorUnicodeScalarOffset)\n".utf8)
        output.append(Data(edit.buffer.utf8))
        output.append(0)
        FileHandle.standardOutput.write(output)
    }

    private static let help = """
    Usage:
      wds-terminal-adapter resolve --surface zsh-zle \\
        --cursor-scalar-offset N [--socket PATH] [--timeout-ms N]

      wds-terminal-adapter resolve --surface interactive-cli \\
        --surface-id ID --cursor-scalar-offset N [--socket PATH] [--timeout-ms N]

    The complete UTF-8 buffer is read only from stdin. Output is `pass\\n`, or
    `replace\\n<CURSOR>\\n<UTF-8 BUFFER><NUL>` after an exact, explicitly accepted
    deletion. Buffer contents are not accepted in command-line arguments or logged.
    """
}

WDSTerminalAdapterCommand.main()
