import Darwin
import Dispatch
import Foundation
import Security
import WDSTerminalAdapterCore

enum TerminalSocketServerError: Error {
    case alreadyRunning
    case unsafeSupportDirectory
    case unsafeTokenFile
    case unsafeSocketFile
    case randomGenerationFailed
    case tokenWriteFailed
    case socketCreationFailed
    case socketConfigurationFailed
    case socketPathTooLong
    case bindFailed
    case listenFailed
}

/// Authenticated local transport for the opt-in Zsh adapter.
///
/// The current resolver intentionally returns pass-through. This establishes the
/// transport without inventing a semantic deletion decision or changing Enter.
final class TerminalSocketServer: @unchecked Sendable {
    typealias Resolver = @Sendable (TerminalResolveRequest) -> TerminalResolveResponse

    private let stateLock = NSLock()
    private let acceptQueue = DispatchQueue(label: "com.heznpc.WDS.terminal.accept")
    private let connectionQueue = DispatchQueue(
        label: "com.heznpc.WDS.terminal.connections",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let resolver: Resolver
    private let supportDirectoryURL: URL
    private let socketURL: URL
    private let tokenURL: URL

    private var readSource: DispatchSourceRead?
    private var listeningDescriptor: Int32 = -1
    private var authenticationToken: String?

    init(
        supportDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/WDS", isDirectory: true),
        resolver: @escaping Resolver = { request in
            TerminalResolveResponse(
                requestID: request.requestID,
                decision: .passThrough
            )
        }
    ) {
        self.supportDirectoryURL = supportDirectoryURL
        socketURL = supportDirectoryURL.appendingPathComponent("terminal.sock", isDirectory: false)
        tokenURL = supportDirectoryURL.appendingPathComponent("terminal.auth", isDirectory: false)
        self.resolver = resolver
    }

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return readSource != nil && listeningDescriptor >= 0
    }

    func start() throws {
        stateLock.lock()
        let alreadyRunning = readSource != nil || listeningDescriptor >= 0
        stateLock.unlock()
        guard !alreadyRunning else { throw TerminalSocketServerError.alreadyRunning }

        try prepareSupportDirectory()
        let token = try rotateAuthenticationToken()
        try removeStaleSocketIfSafe()

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            try? removeTokenIfSafe()
            throw TerminalSocketServerError.socketCreationFailed
        }

        do {
            try configureListeningSocket(descriptor)
            try bindSocket(descriptor)
            guard chmod(socketURL.path, 0o600) == 0 else {
                throw TerminalSocketServerError.socketConfigurationFailed
            }
            guard Darwin.listen(descriptor, 8) == 0 else {
                throw TerminalSocketServerError.listenFailed
            }
        } catch {
            Darwin.close(descriptor)
            try? removeSocketIfSafe()
            try? removeTokenIfSafe()
            throw error
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: acceptQueue)
        source.setEventHandler { [weak self] in
            self?.acceptAvailableConnections()
        }
        source.setCancelHandler {
            Darwin.close(descriptor)
        }

        stateLock.lock()
        listeningDescriptor = descriptor
        authenticationToken = token
        readSource = source
        stateLock.unlock()
        source.resume()
    }

    func stop() {
        stateLock.lock()
        let source = readSource
        readSource = nil
        listeningDescriptor = -1
        authenticationToken = nil
        stateLock.unlock()

        source?.cancel()
        try? removeSocketIfSafe()
        try? removeTokenIfSafe()
    }

    deinit {
        stop()
    }

    private func prepareSupportDirectory() throws {
        var info = stat()
        if lstat(supportDirectoryURL.path, &info) == 0 {
            guard info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFDIR else {
                throw TerminalSocketServerError.unsafeSupportDirectory
            }
            guard chmod(supportDirectoryURL.path, 0o700) == 0 else {
                throw TerminalSocketServerError.unsafeSupportDirectory
            }
        } else {
            guard errno == ENOENT else {
                throw TerminalSocketServerError.unsafeSupportDirectory
            }
            do {
                try FileManager.default.createDirectory(
                    at: supportDirectoryURL,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw TerminalSocketServerError.unsafeSupportDirectory
            }
        }

        guard lstat(supportDirectoryURL.path, &info) == 0,
              info.st_uid == geteuid(),
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o077 == 0 else {
            throw TerminalSocketServerError.unsafeSupportDirectory
        }
    }

    private func rotateAuthenticationToken() throws -> String {
        var randomBytes = [UInt8](repeating: 0, count: 32)
        let randomStatus = randomBytes.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, bytes.count, baseAddress)
        }
        guard randomStatus == errSecSuccess else {
            throw TerminalSocketServerError.randomGenerationFailed
        }
        let token = randomBytes.map { String(format: "%02x", $0) }.joined()

        var existing = stat()
        let exists = lstat(tokenURL.path, &existing) == 0
        if exists {
            guard existing.st_uid == geteuid(),
                  existing.st_mode & S_IFMT == S_IFREG,
                  existing.st_mode & 0o077 == 0 else {
                throw TerminalSocketServerError.unsafeTokenFile
            }
        } else if errno != ENOENT {
            throw TerminalSocketServerError.unsafeTokenFile
        }

        let flags = O_WRONLY | O_CLOEXEC | O_NOFOLLOW | (exists ? O_TRUNC : (O_CREAT | O_EXCL))
        let descriptor = Darwin.open(tokenURL.path, flags, 0o600)
        guard descriptor >= 0 else { throw TerminalSocketServerError.tokenWriteFailed }
        defer { Darwin.close(descriptor) }
        guard fchmod(descriptor, 0o600) == 0 else {
            throw TerminalSocketServerError.tokenWriteFailed
        }

        let data = Data(token.utf8)
        do {
            try writeAllBlocking(data, to: descriptor)
        } catch {
            throw TerminalSocketServerError.tokenWriteFailed
        }
        return token
    }

    private func configureListeningSocket(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw TerminalSocketServerError.socketConfigurationFailed
        }
        var noSignal: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout.size(ofValue: noSignal))
        ) == 0 else {
            throw TerminalSocketServerError.socketConfigurationFailed
        }
    }

    private func bindSocket(_ descriptor: Int32) throws {
        let pathBytes = Array(socketURL.path.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw TerminalSocketServerError.socketPathTooLong
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let addressLength = socklen_t(
            MemoryLayout.size(ofValue: address.sun_len)
                + MemoryLayout.size(ofValue: address.sun_family)
                + pathBytes.count
        )
        guard addressLength <= UInt8.max else {
            throw TerminalSocketServerError.socketPathTooLong
        }
        address.sun_len = UInt8(addressLength)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { bytes in
                for index in pathBytes.indices { bytes[index] = pathBytes[index] }
            }
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, addressLength)
            }
        }
        guard result == 0 else { throw TerminalSocketServerError.bindFailed }
    }

    private func acceptAvailableConnections() {
        while true {
            stateLock.lock()
            let descriptor = listeningDescriptor
            let token = authenticationToken
            stateLock.unlock()
            guard descriptor >= 0, let token else { return }

            let client = Darwin.accept(descriptor, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                return
            }

            connectionQueue.async { [weak self] in
                defer { Darwin.close(client) }
                self?.handleConnection(client, token: token)
            }
        }
    }

    private func handleConnection(_ descriptor: Int32, token: String) {
        guard configureClientSocket(descriptor), peerIsCurrentUser(descriptor) else { return }
        let deadline = TerminalServerDeadline(milliseconds: 5_000)

        do {
            let hello = try readFrame(
                TerminalServerAuthenticationHello.self,
                from: descriptor,
                deadline: deadline
            )
            guard hello.protocolVersion == wdsTerminalProtocolVersion,
                  hello.operation == "authenticate_server",
                  let proof = terminalServerAuthenticationProof(tokenHex: token, nonce: hello.nonce)
            else { return }

            try writeAll(
                try encodeTerminalWireFrame(TerminalServerAuthenticationProof(
                    nonce: hello.nonce,
                    proofHMACSHA256: proof
                )),
                to: descriptor,
                deadline: deadline
            )

            let request = try readFrame(
                TerminalResolveRequest.self,
                from: descriptor,
                deadline: deadline
            )
            guard request.protocolVersion == wdsTerminalProtocolVersion,
                  request.operation == "resolve_accepted_deletion",
                  !request.requestID.isEmpty,
                  request.requestID.utf8.count <= 160,
                  let checkedSnapshot = try? TerminalBufferSnapshot(
                    buffer: request.snapshot.buffer,
                    cursorUnicodeScalarOffset: request.snapshot.cursorUnicodeScalarOffset
                  ),
                  checkedSnapshot.bufferSHA256 == request.snapshot.bufferSHA256
            else { return }

            let response = resolver(request)
            guard response.protocolVersion == wdsTerminalProtocolVersion,
                  response.requestID == request.requestID else { return }
            try writeAll(
                try encodeTerminalWireFrame(response),
                to: descriptor,
                deadline: deadline
            )
        } catch {
            // Fail closed without logging buffer contents or transport details.
        }
    }

    private func configureClientSocket(_ descriptor: Int32) -> Bool {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            return false
        }
        var noSignal: Int32 = 1
        return setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout.size(ofValue: noSignal))
        ) == 0
    }

    private func peerIsCurrentUser(_ descriptor: Int32) -> Bool {
        var effectiveUserID: uid_t = 0
        var effectiveGroupID: gid_t = 0
        return getpeereid(descriptor, &effectiveUserID, &effectiveGroupID) == 0
            && effectiveUserID == geteuid()
    }

    private func readFrame<T: Decodable>(
        _ type: T.Type,
        from descriptor: Int32,
        deadline: TerminalServerDeadline
    ) throws -> T {
        let header = try readExactly(4, from: descriptor, deadline: deadline)
        let bodyLength = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard bodyLength <= UInt32(wdsMaximumWireMessageBytes) else {
            throw TerminalWireViolation.messageTooLarge
        }
        let body = try readExactly(Int(bodyLength), from: descriptor, deadline: deadline)
        return try decodeTerminalWireFrame(type, from: header + body)
    }

    private func readExactly(
        _ count: Int,
        from descriptor: Int32,
        deadline: TerminalServerDeadline
    ) throws -> Data {
        var data = Data(count: count)
        var received = 0
        try data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            while received < count {
                let result = Darwin.recv(
                    descriptor,
                    base.advanced(by: received),
                    count - received,
                    0
                )
                if result > 0 {
                    received += result
                } else if result < 0, errno == EINTR {
                    continue
                } else if result < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    try waitFor(descriptor, events: Int16(POLLIN), deadline: deadline)
                } else {
                    throw POSIXError(.ECONNRESET)
                }
            }
        }
        return data
    }

    private func writeAll(
        _ data: Data,
        to descriptor: Int32,
        deadline: TerminalServerDeadline
    ) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let result = Darwin.send(
                    descriptor,
                    base.advanced(by: written),
                    buffer.count - written,
                    0
                )
                if result > 0 {
                    written += result
                } else if result < 0, errno == EINTR {
                    continue
                } else if result < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    try waitFor(descriptor, events: Int16(POLLOUT), deadline: deadline)
                } else {
                    throw POSIXError(.EPIPE)
                }
            }
        }
    }

    private func waitFor(
        _ descriptor: Int32,
        events: Int16,
        deadline: TerminalServerDeadline
    ) throws {
        while true {
            guard let remaining = deadline.remainingMilliseconds else {
                throw POSIXError(.ETIMEDOUT)
            }
            var pollDescriptor = pollfd(fd: descriptor, events: events, revents: 0)
            let result = Darwin.poll(&pollDescriptor, 1, remaining)
            if result > 0 { return }
            if result == 0 { throw POSIXError(.ETIMEDOUT) }
            if errno != EINTR { throw POSIXError(.EIO) }
        }
    }

    private func removeStaleSocketIfSafe() throws {
        var info = stat()
        guard lstat(socketURL.path, &info) == 0 else {
            if errno == ENOENT { return }
            throw TerminalSocketServerError.unsafeSocketFile
        }
        guard info.st_uid == geteuid(),
              info.st_mode & S_IFMT == S_IFSOCK,
              info.st_mode & 0o077 == 0,
              unlink(socketURL.path) == 0 else {
            throw TerminalSocketServerError.unsafeSocketFile
        }
    }

    private func removeSocketIfSafe() throws {
        try removeOwnedFile(at: socketURL, expectedType: S_IFSOCK)
    }

    private func removeTokenIfSafe() throws {
        try removeOwnedFile(at: tokenURL, expectedType: S_IFREG)
    }

    private func removeOwnedFile(at url: URL, expectedType: mode_t) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return }
            throw TerminalSocketServerError.unsafeSocketFile
        }
        guard info.st_uid == geteuid(),
              info.st_mode & S_IFMT == expectedType,
              info.st_mode & 0o077 == 0,
              unlink(url.path) == 0 else {
            throw TerminalSocketServerError.unsafeSocketFile
        }
    }
}

private struct TerminalServerDeadline {
    let endNanoseconds: UInt64

    init(milliseconds: Int32) {
        endNanoseconds = DispatchTime.now().uptimeNanoseconds
            .addingReportingOverflow(UInt64(milliseconds) * 1_000_000).partialValue
    }

    var remainingMilliseconds: Int32? {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < endNanoseconds else { return nil }
        let roundedUp = (endNanoseconds - now + 999_999) / 1_000_000
        return Int32(min(roundedUp, UInt64(Int32.max)))
    }
}

private func writeAllBlocking(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { buffer in
        guard let base = buffer.baseAddress else { return }
        var written = 0
        while written < buffer.count {
            let result = Darwin.write(
                descriptor,
                base.advanced(by: written),
                buffer.count - written
            )
            if result > 0 {
                written += result
            } else if result < 0, errno == EINTR {
                continue
            } else {
                throw POSIXError(.EIO)
            }
        }
    }
}
