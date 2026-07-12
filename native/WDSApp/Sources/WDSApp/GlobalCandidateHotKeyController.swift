import Carbon.HIToolbox
import Foundation
import WDSAppCore

private let candidateHotKeySignature: OSType = 0x5744_5348 // "WDSH"

private let candidateHotKeyHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    let controller = Unmanaged<GlobalCandidateHotKeyController>
        .fromOpaque(userData)
        .takeUnretainedValue()
    return controller.handle(event: event)
}

/// Registers only two explicit candidate commands. It never observes a global
/// keyboard stream and is active only while an actionable candidate is shown.
final class GlobalCandidateHotKeyController: NSObject {
    private struct ActiveRegistration {
        let session: CandidateCommandSession
        let approveID: UInt32
        let keepID: UInt32
        let approveRef: EventHotKeyRef
        let keepRef: EventHotKeyRef
        let onApprove: () -> Void
        let onKeep: () -> Void
    }

    private let gate = CandidateCommandGate()
    private var eventHandlerRef: EventHandlerRef?
    private var active: ActiveRegistration?
    private var nextEventID: UInt32 = 1

    var isActive: Bool { active != nil }

    override init() {
        super.init()
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            candidateHotKeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
        if status != noErr {
            eventHandlerRef = nil
        }
    }

    deinit {
        deactivate()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    @discardableResult
    func activate(
        onApprove: @escaping () -> Void,
        onKeep: @escaping () -> Void
    ) -> Bool {
        precondition(Thread.isMainThread)
        deactivate()
        guard eventHandlerRef != nil else { return false }

        let session = gate.begin()
        let approveID = allocateEventID()
        let keepID = allocateEventID()
        let modifiers = UInt32(controlKey | cmdKey)
        var approveRef: EventHotKeyRef?
        var keepRef: EventHotKeyRef?

        let approveStatus = RegisterEventHotKey(
            UInt32(kVK_Delete),
            modifiers,
            EventHotKeyID(signature: candidateHotKeySignature, id: approveID),
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &approveRef
        )
        guard approveStatus == noErr, let approveRef else {
            gate.invalidate()
            return false
        }

        let keepStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_K),
            modifiers,
            EventHotKeyID(signature: candidateHotKeySignature, id: keepID),
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &keepRef
        )
        guard keepStatus == noErr, let keepRef else {
            UnregisterEventHotKey(approveRef)
            gate.invalidate()
            return false
        }

        active = ActiveRegistration(
            session: session,
            approveID: approveID,
            keepID: keepID,
            approveRef: approveRef,
            keepRef: keepRef,
            onApprove: onApprove,
            onKeep: onKeep
        )
        return true
    }

    func deactivate() {
        precondition(Thread.isMainThread)
        gate.invalidate()
        guard let active else { return }
        self.active = nil
        UnregisterEventHotKey(active.approveRef)
        UnregisterEventHotKey(active.keepRef)
    }

    fileprivate func handle(event: EventRef) -> OSStatus {
        precondition(Thread.isMainThread)
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr,
              hotKeyID.signature == candidateHotKeySignature,
              let active
        else { return OSStatus(eventNotHandledErr) }

        let command: CandidateCommand
        if hotKeyID.id == active.approveID {
            command = .approve
        } else if hotKeyID.id == active.keepID {
            command = .keep
        } else {
            return OSStatus(eventNotHandledErr)
        }
        guard gate.consume(active.session) else {
            return OSStatus(eventNotHandledErr)
        }

        let callback = command == .approve ? active.onApprove : active.onKeep
        self.active = nil
        UnregisterEventHotKey(active.approveRef)
        UnregisterEventHotKey(active.keepRef)
        callback()
        return noErr
    }

    private func allocateEventID() -> UInt32 {
        let identifier = nextEventID
        nextEventID = nextEventID == UInt32.max ? 1 : nextEventID + 1
        return identifier
    }
}
