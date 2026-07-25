import Foundation

/// A batch of parsed JSON-Lines objects, and whether any line overflowed.
struct JSONLineBatch {
    let objects: [[String: Any]]
    let overflowed: Bool
}

/// Incrementally parses newline-delimited JSON from the sensor's stdout,
/// bounding line size and zeroing the buffer on clear.
final class JSONLineParser {
    private let lock = NSLock()
    private var buffer = Data()
    private let maximumLineSize = 256 * 1_024

    func append(_ data: Data) -> JSONLineBatch {
        lock.lock()
        defer { lock.unlock() }

        buffer.append(data)
        var objects: [[String: Any]] = []
        var overflowed = false

        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            guard line.count <= maximumLineSize else {
                overflowed = true
                continue
            }
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                objects.append(object)
            }
        }

        if buffer.count > maximumLineSize {
            buffer.removeAll(keepingCapacity: false)
            overflowed = true
        }
        return JSONLineBatch(objects: objects, overflowed: overflowed)
    }

    func clear() {
        lock.lock()
        if !buffer.isEmpty {
            buffer.resetBytes(in: buffer.startIndex..<buffer.endIndex)
        }
        buffer.removeAll(keepingCapacity: false)
        lock.unlock()
    }
}

/// One running sensor helper process bound to a target application.
final class SensorSession {
    let identifier = UUID()
    let target: TargetApplication
    let process: Process
    let outputPipe: Pipe
    let rawTextEnabled: Bool
    let textOnly: Bool
    let parser = JSONLineParser()
    var configurationAttested = false
    var focusEpoch: Int?

    init(
        target: TargetApplication,
        process: Process,
        outputPipe: Pipe,
        rawTextEnabled: Bool,
        textOnly: Bool
    ) {
        self.target = target
        self.process = process
        self.outputPipe = outputPipe
        self.rawTextEnabled = rawTextEnabled
        self.textOnly = textOnly
    }
}
