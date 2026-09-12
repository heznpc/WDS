import AppKit
import CoreGraphics
import WDSAppCore
import WDSTerminalAdapterCore

/// Socket workers wait off the main thread; UI lifetime is bounded and a late
/// approval cannot resurrect an expired request.
final class TerminalReviewController: @unchecked Sendable {
    var onBegin: (() -> Bool)?
    var onEnd: (() -> Void)?
    private let panel = CurrentDraftCandidatePanel()
    private let hotKeys = GlobalCandidateHotKeyController()
    private var active: (waiter: TerminalReviewWaiter, targetPID: Int32)?

    func resolve(_ request: TerminalResolveRequest) -> TerminalResolveResponse {
        let waiter = TerminalReviewWaiter(requestID: request.requestID)
        DispatchQueue.main.async { [weak self] in self?.present(request, waiter: waiter) }
        let response = waiter.wait()
        DispatchQueue.main.async { [weak self] in self?.cancel(identifier: waiter.identifier) }
        return response
    }

    func cancelIfTargetChanged(_ processIdentifier: Int32?) {
        if let active, active.targetPID != processIdentifier { cancel() }
    }

    func cancel(identifier: UUID? = nil) {
        guard let active, identifier == nil || identifier == active.waiter.identifier else { return }
        finish(active.waiter, response: active.waiter.passThrough)
    }

    private func present(_ request: TerminalResolveRequest, waiter: TerminalReviewWaiter) {
        guard !waiter.isExpired, active == nil,
              let proposal = TerminalReviewProposal(request: request),
              let target = NSWorkspace.shared.frontmostApplication,
              target.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              onBegin?() == true else {
            waiter.finish(waiter.passThrough)
            return
        }
        active = (waiter, target.processIdentifier)
        let approve: () -> Void = { [weak self] in
            guard let self else { return }
            let stillFocused = target.isActive && !target.isTerminated
                && NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
                && !waiter.isExpired
            self.finish(waiter, response: proposal.response(explicitlyAccepted: stillFocused,
                acceptanceID: waiter.identifier.uuidString))
        }
        let keep: () -> Void = { [weak self] in self?.finish(waiter, response: waiter.passThrough) }
        let shortcuts = hotKeys.activate(onApprove: approve, onKeep: keep)
        let screen = CGDisplayBounds(CGMainDisplayID())
        panel.present(phrase: "터미널 · " + proposal.candidate.originalText.trimmingCharacters(in: .whitespacesAndNewlines),
            targetBounds: CGRect(x: screen.midX - 180, y: screen.midY, width: 360, height: 32),
            keyboardShortcutsAvailable: shortcuts, onApprove: approve, onKeep: keep)
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in self?.cancel(identifier: waiter.identifier) }
    }

    private func finish(_ waiter: TerminalReviewWaiter, response: TerminalResolveResponse) {
        guard active?.waiter.identifier == waiter.identifier else { return }
        active = nil
        hotKeys.deactivate()
        panel.dismiss()
        waiter.finish(response)
        onEnd?()
    }
}

private final class TerminalReviewWaiter: @unchecked Sendable {
    let identifier = UUID()
    let passThrough: TerminalResolveResponse
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private let deadline = DispatchTime.now() + 12
    private var response: TerminalResolveResponse?

    init(requestID: String) { passThrough = TerminalResolveResponse(requestID: requestID, decision: .passThrough) }
    var isExpired: Bool { DispatchTime.now() >= deadline }

    func finish(_ value: TerminalResolveResponse) {
        lock.lock()
        defer { lock.unlock() }
        guard response == nil else { return }
        response = isExpired ? passThrough : value
        semaphore.signal()
    }

    func wait() -> TerminalResolveResponse {
        _ = semaphore.wait(timeout: deadline)
        lock.lock()
        defer { lock.unlock() }
        if response == nil { response = passThrough }
        return response ?? passThrough
    }
}
