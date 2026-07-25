import Darwin
import Foundation

enum EphemeralLaunchError: Error {
    case cancelled
}

/// Tracks short-lived helper processes so they can all be cancelled at once and
/// never outlive a disabled engine. Rejects launches once no longer accepting.
final class EphemeralProcessRegistry {
    private let lock = NSLock()
    private var accepting = false
    private var processes: [UUID: Process] = [:]

    func setAccepting(_ accepting: Bool) {
        lock.lock()
        self.accepting = accepting
        lock.unlock()
    }

    func start(
        _ process: Process,
        terminationHandler: ((UUID, Process) -> Void)? = nil
    ) throws -> UUID {
        let identifier = UUID()
        lock.lock()
        guard accepting else {
            lock.unlock()
            throw EphemeralLaunchError.cancelled
        }
        processes[identifier] = process
        lock.unlock()

        if let terminationHandler {
            process.terminationHandler = { [weak self] finishedProcess in
                self?.finish(identifier)
                terminationHandler(identifier, finishedProcess)
            }
        }

        do {
            try process.run()
        } catch {
            finish(identifier)
            throw error
        }

        lock.lock()
        let shouldContinue = accepting && processes[identifier] != nil
        lock.unlock()
        guard shouldContinue else {
            if process.isRunning { process.terminate() }
            finish(identifier)
            throw EphemeralLaunchError.cancelled
        }
        return identifier
    }

    func finish(_ identifier: UUID) {
        lock.lock()
        processes.removeValue(forKey: identifier)
        lock.unlock()
    }

    func cancelAll(wait: Bool) {
        lock.lock()
        accepting = false
        let running = Array(processes.values)
        processes.removeAll()
        lock.unlock()

        for process in running where process.isRunning {
            process.terminate()
        }
        guard wait else { return }

        let deadline = Date().addingTimeInterval(0.25)
        while Date() < deadline, running.contains(where: { $0.isRunning }) {
            usleep(10_000)
        }
        for process in running where process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }
}
