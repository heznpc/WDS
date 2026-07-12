import Darwin
import Dispatch
import Foundation
import WDSTerminalAdapterCore

enum UnixSocketCallbackError: Error {
    case invalidPath
    case unsafeSocket
    case socketCreationFailed
    case socketOptionFailed
    case connectFailed
    case pollFailed
    case deadlineExceeded
    case authenticationFailed
    case writeFailed
    case readFailed
    case invalidFrame
}

struct UnixSocketCallbackClient {
    let path: String
    let timeoutMilliseconds: Int32
    let authenticationToken: String

    func resolve(_ request: TerminalResolveRequest) throws -> TerminalResolveResponse {
        try validateSocketPath()
        let deadline = MonotonicDeadline(milliseconds: timeoutMilliseconds)
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw UnixSocketCallbackError.socketCreationFailed
        }
        defer { Darwin.close(descriptor) }

        try configure(descriptor)
        try connect(descriptor, deadline: deadline)

        // Authenticate the server before transmitting any user buffer. A process
        // that merely pre-binds the predictable socket path sees only a nonce.
        let nonce = UUID().uuidString.lowercased()
        let hello = TerminalServerAuthenticationHello(nonce: nonce)
        try writeAll(
            try encodeTerminalWireFrame(hello),
            to: descriptor,
            deadline: deadline
        )
        let proof = try readFrame(
            TerminalServerAuthenticationProof.self,
            from: descriptor,
            deadline: deadline
        )
        guard verifyTerminalServerAuthenticationProof(
            proof,
            tokenHex: authenticationToken,
            nonce: nonce
        ) else {
            throw UnixSocketCallbackError.authenticationFailed
        }

        try writeAll(
            try encodeTerminalWireFrame(request),
            to: descriptor,
            deadline: deadline
        )
        return try readFrame(
            TerminalResolveResponse.self,
            from: descriptor,
            deadline: deadline
        )
    }

    private func validateSocketPath() throws {
        guard path.hasPrefix("/"), path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw UnixSocketCallbackError.invalidPath
        }

        var socketInfo = stat()
        guard lstat(path, &socketInfo) == 0,
              socketInfo.st_uid == geteuid(),
              socketInfo.st_mode & S_IFMT == S_IFSOCK,
              socketInfo.st_mode & 0o077 == 0 else {
            throw UnixSocketCallbackError.unsafeSocket
        }

        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        var parentInfo = stat()
        guard lstat(parent, &parentInfo) == 0,
              parentInfo.st_uid == geteuid(),
              parentInfo.st_mode & S_IFMT == S_IFDIR,
              parentInfo.st_mode & 0o022 == 0 else {
            throw UnixSocketCallbackError.unsafeSocket
        }
    }

    private func configure(_ descriptor: Int32) throws {
        var noSignal: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout.size(ofValue: noSignal))
        ) == 0 else {
            throw UnixSocketCallbackError.socketOptionFailed
        }

    }

    private func connect(_ descriptor: Int32, deadline: MonotonicDeadline) throws {
        let originalFlags = fcntl(descriptor, F_GETFL)
        guard originalFlags >= 0,
              fcntl(descriptor, F_SETFL, originalFlags | O_NONBLOCK) == 0 else {
            throw UnixSocketCallbackError.connectFailed
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        let addressLength = socklen_t(
            MemoryLayout.size(ofValue: address.sun_len)
                + MemoryLayout.size(ofValue: address.sun_family)
                + pathBytes.count
        )
        guard addressLength <= UInt8.max else {
            throw UnixSocketCallbackError.invalidPath
        }
        address.sun_len = UInt8(addressLength)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { bytes in
                for index in pathBytes.indices {
                    bytes[index] = pathBytes[index]
                }
            }
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, addressLength)
            }
        }
        if result == 0 {
            return
        }
        guard errno == EINPROGRESS else {
            throw UnixSocketCallbackError.connectFailed
        }

        try waitFor(descriptor, events: Int16(POLLOUT), deadline: deadline)

        var socketError: Int32 = 0
        var socketErrorLength = socklen_t(MemoryLayout.size(ofValue: socketError))
        guard getsockopt(
            descriptor,
            SOL_SOCKET,
            SO_ERROR,
            &socketError,
            &socketErrorLength
        ) == 0,
        socketError == 0 else {
            throw UnixSocketCallbackError.connectFailed
        }
    }

    private func writeAll(
        _ data: Data,
        to descriptor: Int32,
        deadline: MonotonicDeadline
    ) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let result = Darwin.send(
                    descriptor,
                    baseAddress.advanced(by: written),
                    rawBuffer.count - written,
                    0
                )
                if result > 0 {
                    written += result
                } else if result < 0, errno == EINTR {
                    continue
                } else if result < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    try waitFor(descriptor, events: Int16(POLLOUT), deadline: deadline)
                } else {
                    throw UnixSocketCallbackError.writeFailed
                }
            }
        }
    }

    private func readExactly(
        _ count: Int,
        from descriptor: Int32,
        deadline: MonotonicDeadline
    ) throws -> Data {
        var data = Data(count: count)
        var received = 0
        try data.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            while received < count {
                let result = Darwin.recv(
                    descriptor,
                    baseAddress.advanced(by: received),
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
                    throw UnixSocketCallbackError.readFailed
                }
            }
        }
        return data
    }

    private func readFrame<T: Decodable>(
        _ type: T.Type,
        from descriptor: Int32,
        deadline: MonotonicDeadline
    ) throws -> T {
        let header = try readExactly(
            MemoryLayout<UInt32>.size,
            from: descriptor,
            deadline: deadline
        )
        let bodyLength = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard bodyLength <= UInt32(wdsMaximumWireMessageBytes) else {
            throw UnixSocketCallbackError.invalidFrame
        }
        let body = try readExactly(Int(bodyLength), from: descriptor, deadline: deadline)
        var frame = header
        frame.append(body)
        return try decodeTerminalWireFrame(type, from: frame)
    }

    private func waitFor(
        _ descriptor: Int32,
        events: Int16,
        deadline: MonotonicDeadline
    ) throws {
        while true {
            guard let remaining = deadline.remainingMilliseconds else {
                throw UnixSocketCallbackError.deadlineExceeded
            }
            var item = pollfd(fd: descriptor, events: events, revents: 0)
            let result = Darwin.poll(&item, 1, remaining)
            if result > 0 {
                return
            }
            if result == 0 {
                throw UnixSocketCallbackError.deadlineExceeded
            }
            if errno != EINTR {
                throw UnixSocketCallbackError.pollFailed
            }
        }
    }
}

private struct MonotonicDeadline {
    let endNanoseconds: UInt64

    init(milliseconds: Int32) {
        let duration = UInt64(milliseconds) * 1_000_000
        self.endNanoseconds = DispatchTime.now().uptimeNanoseconds.addingReportingOverflow(duration).partialValue
    }

    var remainingMilliseconds: Int32? {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < endNanoseconds else { return nil }
        let remainingNanoseconds = endNanoseconds - now
        let roundedUpMilliseconds = (remainingNanoseconds + 999_999) / 1_000_000
        return Int32(min(roundedUpMilliseconds, UInt64(Int32.max)))
    }
}
