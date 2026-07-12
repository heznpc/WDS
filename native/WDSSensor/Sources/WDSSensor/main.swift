import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import WDSSensorCore

private typealias CLIOptions = SensorCLIOptions

private func parseCLIOptions(_ arguments: [String]) throws -> CLIOptions? {
    do {
        return try CLIOptions.parse(arguments)
    } catch let failure as SensorCLIParseFailure {
        throw SensorFailure(failure.code, failure.message)
    }
}

private struct SensorFailure: Error, @unchecked Sendable {
    let code: String
    let message: String
    let details: [String: Any]

    init(_ code: String, _ message: String, details: [String: Any] = [:]) {
        self.code = code
        self.message = message
        self.details = details
    }
}

private final class JSONLineWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var outputOrder = SensorOutputOrderGate()

    func write(_ value: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }

        if let eventType = value["type"] as? String {
            guard outputOrder.permits(eventType: eventType) else {
                assertionFailure("Focus-scoped sensor output preceded sensor_started.")
                return
            }
            if SensorOutputOrderGate.requiresFocusEpoch(eventType: eventType) {
                guard value["focus_epoch"] is UInt64 || value["focus_epoch"] is Int else {
                    assertionFailure("Focus-scoped sensor output omitted focus_epoch.")
                    return
                }
            }
        }

        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}

private final class MouseStore: @unchecked Sendable {
    private let lock = NSLock()
    private var ring: MouseActivityRing
    private var revision = UInt64(0)
    private var captureEnabled = false

    init(windowMilliseconds: Double) {
        ring = MouseActivityRing(capacity: 4_096, windowMilliseconds: windowMilliseconds)
    }

    func append(_ sample: MouseSample) {
        lock.lock()
        guard captureEnabled else {
            lock.unlock()
            return
        }
        ring.append(sample)
        revision &+= 1
        lock.unlock()
    }

    func enableFreshCapture() {
        lock.lock()
        ring.removeAll()
        captureEnabled = true
        revision &+= 1
        lock.unlock()
    }

    func disableAndClear() {
        lock.lock()
        ring.removeAll()
        captureEnabled = false
        revision &+= 1
        lock.unlock()
    }

    func snapshot(nowMilliseconds: Double) -> (MouseActivitySummary, UInt64, Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (ring.summary(nowMilliseconds: nowMilliseconds), revision, captureEnabled)
    }
}

private func monotonicMilliseconds() -> Double {
    ProcessInfo.processInfo.systemUptime * 1_000
}

private func wallClockTimestamp() -> String {
    ISO8601DateFormatter().string(from: Date())
}

private func jsonNullable<T>(_ value: T?) -> Any {
    value ?? NSNull()
}

private func mouseTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<MouseMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    monitor.receive(type: type, event: event)
    return Unmanaged.passUnretained(event)
}

private final class MouseMonitor: @unchecked Sendable {
    private let store: MouseStore
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(store: MouseStore) {
        self.store = store
    }

    func start() throws {
        let types: [CGEventType] = [
            .mouseMoved,
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
            .scrollWheel,
        ]
        let mask = types.reduce(CGEventMask(0)) { partial, type in
            partial | (CGEventMask(1) << type.rawValue)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: mouseTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw SensorFailure(
                "mouse_event_tap_unavailable",
                "A listen-only mouse event tap could not be created. Verify Input Monitoring permission manually."
            )
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            throw SensorFailure("mouse_event_tap_source_failed", "The mouse event tap run-loop source could not be created.")
        }

        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func receive(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }

        let now = monotonicMilliseconds()
        switch type {
        case .mouseMoved:
            let point = event.location
            store.append(MouseSample(timestampMilliseconds: now, kind: .move, x: point.x, y: point.y))
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let point = event.location
            store.append(MouseSample(timestampMilliseconds: now, kind: .drag, x: point.x, y: point.y))
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            store.append(MouseSample(timestampMilliseconds: now, kind: .click))
        case .scrollWheel:
            let scrollY = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
            let scrollX = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
            store.append(
                MouseSample(
                    timestampMilliseconds: now,
                    kind: .scroll,
                    scrollX: scrollX,
                    scrollY: scrollY
                )
            )
        default:
            break
        }
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
        runLoopSource = nil
        eventTap = nil
    }
}

private func accessibilityCallback(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let sensor = Unmanaged<FocusedTextSensor>.fromOpaque(refcon).takeUnretainedValue()
    sensor.receive(element: element, notification: notification as String)
}

private enum FocusState {
    case unobserved
    case unavailable
    case element(AXUIElement)
}

private enum AXStringAttributeRead {
    case value(String)
    case absent
    case unavailable(axError: AXError?, reason: String)

    var policyValue: FocusSecurityAttributeValue {
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

private enum FocusSecurityAssessment {
    case allow(role: String, subrole: String?)
    case secure(role: String?, subrole: String?)
    case unavailable(
        attribute: FocusSecurityAttribute,
        read: AXStringAttributeRead,
        role: String?,
        subrole: String?
    )
}

private final class FocusedTextSensor: @unchecked Sendable {
    private let bundleIdentifier: String
    private let application: NSRunningApplication
    private let applicationElement: AXUIElement
    private let mouseStore: MouseStore
    private let writer: JSONLineWriter
    private let textDisclosurePlan: SensorTextDisclosurePlan
    private let mouseCaptureEnabled: Bool

    private var observer: AXObserver?
    private var observedElement: AXUIElement?
    private var workspaceTokens: [NSObjectProtocol] = []
    private var focusState = FocusState.unobserved
    private var focusEpoch = FocusEpochCounter()
    private var didBeginAfterAttestation = false

    init(
        bundleIdentifier: String,
        application: NSRunningApplication,
        mouseStore: MouseStore,
        writer: JSONLineWriter,
        emitText: Bool,
        mouseCaptureEnabled: Bool
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.application = application
        applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        self.mouseStore = mouseStore
        self.writer = writer
        textDisclosurePlan = SensorTextDisclosurePlan(emitText: emitText)
        self.mouseCaptureEnabled = mouseCaptureEnabled
    }

    /// Installs observation plumbing without reading or emitting any focused
    /// text. SensorRunner emits its configuration attestation before calling
    /// beginAfterAttestation().
    func prepare() throws {
        var createdObserver: AXObserver?
        let createError = AXObserverCreate(application.processIdentifier, accessibilityCallback, &createdObserver)
        guard createError == .success, let createdObserver else {
            throw SensorFailure(
                "accessibility_observer_failed",
                "The Accessibility observer could not be created.",
                details: ["axError": createError.rawValue]
            )
        }
        observer = createdObserver

        let context = Unmanaged.passUnretained(self).toOpaque()
        for notification in [
            kAXFocusedUIElementChangedNotification,
            kAXFocusedWindowChangedNotification,
        ] {
            let error = AXObserverAddNotification(
                createdObserver,
                applicationElement,
                notification as CFString,
                context
            )
            let isRequiredFocusNotification = notification == kAXFocusedUIElementChangedNotification
            let isAccepted = error == .success
                || error == .notificationAlreadyRegistered
                || (!isRequiredFocusNotification && error == .notificationUnsupported)
            if !isAccepted {
                throw SensorFailure(
                    "accessibility_notification_failed",
                    "An Accessibility focus notification could not be registered.",
                    details: ["notification": notification, "axError": error.rawValue]
                )
            }
        }

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(createdObserver),
            .commonModes
        )
        installWorkspaceObservers()
    }

    func beginAfterAttestation() {
        guard !didBeginAfterAttestation else { return }
        didBeginAfterAttestation = true
        emitAppFocus(active: application.isActive, reason: "initial")
        if application.isActive {
            refreshFocusedElement(reason: "initial")
        }
    }

    func receive(element: AXUIElement, notification: String) {
        guard didBeginAfterAttestation else { return }
        switch notification {
        case kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification:
            guard application.isActive else {
                detachObservedElement()
                _ = transitionFocus(to: .unavailable)
                return
            }
            refreshFocusedElement(reason: "focus_changed")
        case kAXValueChangedNotification:
            guard application.isActive,
                  let observedElement,
                  CFEqual(observedElement, element)
            else { return }
            guard isCurrentlyFocused(observedElement) else {
                refreshFocusedElement(reason: "focus_revalidated")
                return
            }
            emitTextSnapshot(from: observedElement, reason: "value_changed")
        default:
            break
        }
    }

    private func installWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(
            center.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self,
                      self.didBeginAfterAttestation,
                      self.isTargetApplication(notification)
                else { return }
                self.mouseStore.disableAndClear()
                self.emitAppFocus(active: true, reason: "activated")
                self.refreshFocusedElement(reason: "app_activated")
            }
        )
        workspaceTokens.append(
            center.addObserver(
                forName: NSWorkspace.didDeactivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self,
                      self.didBeginAfterAttestation,
                      self.isTargetApplication(notification)
                else { return }
                self.detachObservedElement()
                _ = self.transitionFocus(to: .unavailable)
                self.emitAppFocus(active: false, reason: "deactivated")
            }
        )
        workspaceTokens.append(
            center.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self,
                      self.didBeginAfterAttestation,
                      self.isTargetApplication(notification)
                else { return }
                self.detachObservedElement()
                _ = self.transitionFocus(to: .unavailable)
                self.writer.write([
                    "type": "target_app_terminated",
                    "timestamp": wallClockTimestamp(),
                    "bundle_id": self.bundleIdentifier,
                    "pid": self.application.processIdentifier,
                ])
                CFRunLoopStop(CFRunLoopGetMain())
            }
        )
    }

    private func isTargetApplication(_ notification: Notification) -> Bool {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return false
        }
        return app.processIdentifier == application.processIdentifier
    }

    private func isCurrentlyFocused(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedUIElementAttribute as CFString,
            &value
        )
        guard error == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return false }
        let focusedElement = unsafeDowncast(value, to: AXUIElement.self)
        return CFEqual(focusedElement, element)
    }

    private func refreshFocusedElement(reason: String) {
        var value: CFTypeRef?
        let focusError = AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedUIElementAttribute as CFString,
            &value
        )
        guard focusError == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            detachObservedElement()
            let epoch = transitionFocus(to: .unavailable)
            writer.write([
                "type": "focused_element_ignored",
                "timestamp": wallClockTimestamp(),
                "bundle_id": bundleIdentifier,
                "pid": application.processIdentifier,
                "focus_epoch": epoch,
                "reason": "focused_element_unavailable",
                "ax_error": focusError.rawValue,
            ])
            return
        }
        let element = unsafeDowncast(value, to: AXUIElement.self)
        let epoch = transitionFocus(to: .element(element))
        detachObservedElement()

        // Role and subrole are intentionally checked before AXValue. A secure field
        // is never registered for value changes and its value is never requested.
        let role: String
        let subrole: String?
        switch assessSecurityMetadata(for: element) {
        case .allow(let safeRole, let safeSubrole):
            role = safeRole
            subrole = safeSubrole
        case .secure(let secureRole, let secureSubrole):
            writer.write([
                "type": "secure_field_ignored",
                "timestamp": wallClockTimestamp(),
                "bundle_id": bundleIdentifier,
                "pid": application.processIdentifier,
                "focus_epoch": epoch,
                "role": jsonNullable(secureRole),
                "subrole": jsonNullable(secureSubrole),
            ])
            return
        case .unavailable(let attribute, let read, let knownRole, let knownSubrole):
            var payload: [String: Any] = [
                "type": "focused_element_ignored",
                "timestamp": wallClockTimestamp(),
                "bundle_id": bundleIdentifier,
                "pid": application.processIdentifier,
                "focus_epoch": epoch,
                "reason": "security_metadata_unavailable",
                "attribute": attribute.rawValue,
                "role": jsonNullable(knownRole),
                "subrole": jsonNullable(knownSubrole),
            ]
            addAttributeFailureDetails(read, to: &payload)
            writer.write(payload)
            return
        }

        var settable = DarwinBoolean(false)
        let settableError = AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &settable
        )
        guard settableError == .success, settable.boolValue else {
            writer.write([
                "type": "focused_element_ignored",
                "timestamp": wallClockTimestamp(),
                "bundle_id": bundleIdentifier,
                "pid": application.processIdentifier,
                "focus_epoch": epoch,
                "reason": "not_editable_text",
                "role": jsonNullable(role),
                "subrole": jsonNullable(subrole),
            ])
            return
        }

        guard let observer else {
            writer.write([
                "type": "focused_element_ignored",
                "timestamp": wallClockTimestamp(),
                "bundle_id": bundleIdentifier,
                "pid": application.processIdentifier,
                "focus_epoch": epoch,
                "reason": "observer_unavailable",
                "role": role,
                "subrole": jsonNullable(subrole),
            ])
            return
        }
        let notificationError = AXObserverAddNotification(
            observer,
            element,
            kAXValueChangedNotification as CFString,
            Unmanaged.passUnretained(self).toOpaque()
        )
        guard notificationError == .success || notificationError == .notificationAlreadyRegistered else {
            writer.write([
                "type": "focused_element_ignored",
                "timestamp": wallClockTimestamp(),
                "bundle_id": bundleIdentifier,
                "pid": application.processIdentifier,
                "focus_epoch": epoch,
                "reason": "value_notification_unavailable",
                "ax_error": notificationError.rawValue,
                "role": jsonNullable(role),
                "subrole": jsonNullable(subrole),
            ])
            return
        }

        observedElement = element
        if mouseCaptureEnabled {
            mouseStore.enableFreshCapture()
        } else {
            mouseStore.disableAndClear()
        }
        emitTextSnapshot(from: element, reason: reason)
    }

    private func emitTextSnapshot(from element: AXUIElement, reason: String) {
        let epoch = focusEpoch.observeFocus(didChange: false)

        // Recheck before every read in case an app reused an accessibility object and
        // changed its role while focus was moving.
        let role: String
        let subrole: String?
        switch assessSecurityMetadata(for: element) {
        case .allow(let safeRole, let safeSubrole):
            role = safeRole
            subrole = safeSubrole
        case .secure(let secureRole, let secureSubrole):
            detachObservedElement()
            writer.write([
                "type": "secure_field_ignored",
                "timestamp": wallClockTimestamp(),
                "bundle_id": bundleIdentifier,
                "pid": application.processIdentifier,
                "focus_epoch": epoch,
                "role": jsonNullable(secureRole),
                "subrole": jsonNullable(secureSubrole),
            ])
            return
        case .unavailable(let attribute, let read, let knownRole, let knownSubrole):
            detachObservedElement()
            var payload: [String: Any] = [
                "type": "focused_element_ignored",
                "timestamp": wallClockTimestamp(),
                "bundle_id": bundleIdentifier,
                "pid": application.processIdentifier,
                "focus_epoch": epoch,
                "reason": "security_metadata_unavailable",
                "attribute": attribute.rawValue,
                "role": jsonNullable(knownRole),
                "subrole": jsonNullable(knownSubrole),
            ]
            addAttributeFailureDetails(read, to: &payload)
            writer.write(payload)
            return
        }

        let now = monotonicMilliseconds()
        let (mouseSummary, _, _) = mouseStore.snapshot(nowMilliseconds: now)
        var payload: [String: Any] = [
            "type": "text_snapshot",
            "timestamp": wallClockTimestamp(),
            "bundle_id": bundleIdentifier,
            "pid": application.processIdentifier,
            "focus_epoch": epoch,
            "reason": reason,
            "role": role,
            "subrole": jsonNullable(subrole),
            "utf16_length": NSNull(),
            "text_redacted": textDisclosurePlan.textRedacted,
            "recent_mouse": mouseDictionary(mouseSummary),
        ]

        // In the default redacted mode, even the helper process never reads the
        // focused AXValue. This prevents raw text and its length from entering
        // memory merely to produce a redacted event.
        guard textDisclosurePlan.readsAccessibilityValue else {
            writer.write(payload)
            return
        }

        // Revalidate immediately before the only raw-value access. Focus can
        // move after a queued value notification or during metadata checks.
        guard isCurrentlyFocused(element) else {
            refreshFocusedElement(reason: "focus_revalidated_before_value")
            return
        }

        var rawValue: CFTypeRef?
        let valueError = AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &rawValue
        )
        guard valueError == .success, let rawValue else {
            writer.write([
                "type": "text_snapshot_error",
                "timestamp": wallClockTimestamp(),
                "bundle_id": bundleIdentifier,
                "pid": application.processIdentifier,
                "focus_epoch": epoch,
                "reason": "value_unavailable",
                "ax_error": valueError.rawValue,
            ])
            return
        }

        let text: String
        if let value = rawValue as? String {
            text = value
        } else if let value = rawValue as? NSAttributedString {
            text = value.string
        } else {
            writer.write([
                "type": "text_snapshot_error",
                "timestamp": wallClockTimestamp(),
                "bundle_id": bundleIdentifier,
                "pid": application.processIdentifier,
                "focus_epoch": epoch,
                "reason": "value_not_text",
            ])
            return
        }

        payload["utf16_length"] = (text as NSString).length
        payload["text"] = text
        writer.write(payload)
    }

    private func detachObservedElement() {
        mouseStore.disableAndClear()
        if let observer, let observedElement {
            _ = AXObserverRemoveNotification(
                observer,
                observedElement,
                kAXValueChangedNotification as CFString
            )
        }
        observedElement = nil
    }

    private func readStringAttribute(
        _ element: AXUIElement,
        _ attribute: String,
        securityAttribute: FocusSecurityAttribute
    ) -> AXStringAttributeRead {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        switch focusSecurityAttributeReadStatus(error: error, attribute: securityAttribute) {
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

    private func assessSecurityMetadata(for element: AXUIElement) -> FocusSecurityAssessment {
        let roleRead = readStringAttribute(
            element,
            kAXRoleAttribute,
            securityAttribute: .role
        )

        // A known secure role is sufficient to reject the field; querying more
        // metadata cannot make reading AXValue safer.
        if focusSecurityDecision(role: roleRead.policyValue, subrole: .unavailable) == .secure {
            return .secure(role: roleRead.stringValue, subrole: nil)
        }
        guard case .value(let role) = roleRead else {
            return .unavailable(attribute: .role, read: roleRead, role: nil, subrole: nil)
        }

        let subroleRead = readStringAttribute(
            element,
            kAXSubroleAttribute,
            securityAttribute: .subrole
        )
        switch focusSecurityDecision(role: roleRead.policyValue, subrole: subroleRead.policyValue) {
        case .allow:
            return .allow(role: role, subrole: subroleRead.stringValue)
        case .secure:
            return .secure(role: role, subrole: subroleRead.stringValue)
        case .ignore(let unavailableAttribute):
            return .unavailable(
                attribute: unavailableAttribute,
                read: unavailableAttribute == .role ? roleRead : subroleRead,
                role: role,
                subrole: subroleRead.stringValue
            )
        }
    }

    private func addAttributeFailureDetails(
        _ read: AXStringAttributeRead,
        to payload: inout [String: Any]
    ) {
        guard case .unavailable(let axError, let reason) = read else { return }
        payload["metadata_error"] = reason
        if let axError {
            payload["ax_error"] = axError.rawValue
        }
    }

    private func transitionFocus(to newState: FocusState) -> UInt64 {
        let didChange: Bool
        switch (focusState, newState) {
        case (.unobserved, _):
            didChange = true
        case (.unavailable, .unavailable):
            didChange = false
        case (.element(let oldElement), .element(let newElement)):
            didChange = !CFEqual(oldElement, newElement)
        case (.unavailable, .element), (.element, .unavailable):
            didChange = true
        case (_, .unobserved):
            didChange = true
        }
        focusState = newState
        return focusEpoch.observeFocus(didChange: didChange)
    }

    private func emitAppFocus(active: Bool, reason: String) {
        writer.write([
            "type": "app_focus",
            "timestamp": wallClockTimestamp(),
            "bundle_id": bundleIdentifier,
            "pid": application.processIdentifier,
            "active": active,
            "reason": reason,
        ])
    }

    func stop() {
        detachObservedElement()
        let center = NSWorkspace.shared.notificationCenter
        for token in workspaceTokens {
            center.removeObserver(token)
        }
        workspaceTokens.removeAll()

        if let observer {
            _ = AXObserverRemoveNotification(
                observer,
                applicationElement,
                kAXFocusedUIElementChangedNotification as CFString
            )
            _ = AXObserverRemoveNotification(
                observer,
                applicationElement,
                kAXFocusedWindowChangedNotification as CFString
            )
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .commonModes
            )
        }
        observer = nil
    }
}

private func mouseDictionary(_ summary: MouseActivitySummary) -> [String: Any] {
    [
        "window_ms": summary.windowMilliseconds,
        "event_count": summary.eventCount,
        "movement_count": summary.movementCount,
        "click_count": summary.clickCount,
        "scroll_event_count": summary.scrollEventCount,
        "distance_points": summary.distancePoints,
        "average_speed_points_per_second": summary.averageSpeedPointsPerSecond,
        "direction": summary.direction,
        "scroll_x": summary.scrollX,
        "scroll_y": summary.scrollY,
    ]
}

private final class SensorRunner: @unchecked Sendable {
    private let options: CLIOptions
    private let writer: JSONLineWriter
    private let mouseStore: MouseStore
    private let mouseMonitor: MouseMonitor
    private let textSensor: FocusedTextSensor
    private let runtimePlan: SensorRuntimePlan
    private var summaryTimer: Timer?
    private var durationTimer: Timer?
    private var lastMouseRevision = UInt64(0)
    private var stopGate = SensorStopGate()
    private var didCleanup = false
    let targetProcessIdentifier: pid_t

    init(options: CLIOptions) throws {
        self.options = options
        writer = JSONLineWriter()
        mouseStore = MouseStore(windowMilliseconds: options.mouseWindowMilliseconds)
        mouseMonitor = MouseMonitor(store: mouseStore)
        let selectedRuntimePlan = SensorRuntimePlan(textOnly: options.textOnly)
        runtimePlan = selectedRuntimePlan

        let applications = NSRunningApplication.runningApplications(
            withBundleIdentifier: options.bundleIdentifier
        ).filter { !$0.isTerminated }
        guard !applications.isEmpty else {
            throw SensorFailure(
                "target_app_not_running",
                "No running app matches the requested bundle identifier.",
                details: ["bundleIdentifier": options.bundleIdentifier]
            )
        }

        let application: NSRunningApplication
        if applications.count == 1 {
            application = applications[0]
        } else if let active = applications.first(where: \.isActive) {
            application = active
        } else {
            throw SensorFailure(
                "ambiguous_target_app",
                "More than one running process matches the bundle identifier and none is active.",
                details: [
                    "bundleIdentifier": options.bundleIdentifier,
                    "processCount": applications.count,
                ]
            )
        }
        targetProcessIdentifier = application.processIdentifier

        textSensor = FocusedTextSensor(
            bundleIdentifier: options.bundleIdentifier,
            application: application,
            mouseStore: mouseStore,
            writer: writer,
            emitText: options.emitText,
            mouseCaptureEnabled: selectedRuntimePlan.usesMouseCapture
        )
    }

    func run() throws {
        if runtimePlan.usesMouseCapture {
            try mouseMonitor.start()
        }
        do {
            try textSensor.prepare()
        } catch {
            textSensor.stop()
            if runtimePlan.usesMouseCapture {
                mouseMonitor.stop()
            }
            throw error
        }

        // This must precede beginAfterAttestation(): that method performs the
        // initial AXValue read when raw text was explicitly requested.
        writer.write([
            "type": "sensor_started",
            "timestamp": wallClockTimestamp(),
            "bundle_id": options.bundleIdentifier,
            "pid": targetProcessIdentifier,
            "mouse_window_ms": options.mouseWindowMilliseconds,
            "duration_ms": jsonNullable(options.durationMilliseconds),
            "capture_scope": "focused_editable_non_secure_text",
            "raw_text_enabled": options.emitText,
            "text_only": options.textOnly,
            "input_monitoring_required": runtimePlan.requiresInputMonitoringPermission,
            "mouse_output": runtimePlan.mouseOutputAttestation,
            "persistence": "none",
            "focus_epoch_scope": "sensor_session",
        ])
        textSensor.beginAfterAttestation()

        if runtimePlan.emitsMouseSummaries {
            summaryTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                self?.emitMouseSummaryIfChanged()
            }
        }

        if let durationMilliseconds = options.durationMilliseconds {
            durationTimer = Timer.scheduledTimer(
                withTimeInterval: durationMilliseconds / 1_000,
                repeats: false
            ) { [weak self] _ in
                self?.stop(reason: "duration_elapsed")
            }
        }

        CFRunLoopRun()
        if !stopGate.isStopped {
            stop(reason: "run_loop_ended", stopRunLoop: false)
        }
    }

    private func emitMouseSummaryIfChanged() {
        guard runtimePlan.emitsMouseSummaries, !stopGate.isStopped else { return }
        let (summary, revision, captureEnabled) = mouseStore.snapshot(
            nowMilliseconds: monotonicMilliseconds()
        )
        guard revision != lastMouseRevision else { return }
        lastMouseRevision = revision
        guard captureEnabled, summary.eventCount > 0 else { return }
        writer.write([
            "type": "mouse_summary",
            "timestamp": wallClockTimestamp(),
            "bundle_id": options.bundleIdentifier,
            "pid": targetProcessIdentifier,
            "summary": mouseDictionary(summary),
        ])
    }

    private func stop(reason: String, stopRunLoop: Bool = true) {
        guard stopGate.beginStopping() else { return }
        cleanup()
        writer.write([
            "type": "sensor_stopped",
            "timestamp": wallClockTimestamp(),
            "bundle_id": options.bundleIdentifier,
            "pid": targetProcessIdentifier,
            "reason": reason,
        ])
        if stopRunLoop {
            CFRunLoopStop(CFRunLoopGetMain())
        }
    }

    private func cleanup() {
        guard !didCleanup else { return }
        didCleanup = true

        mouseStore.disableAndClear()
        summaryTimer?.invalidate()
        durationTimer?.invalidate()
        summaryTimer = nil
        durationTimer = nil
        textSensor.stop()
        mouseMonitor.stop()
    }
}

@main
private enum WDSSensor {
    static func main() {
        var errorBundleIdentifier: String?
        var errorProcessIdentifier: pid_t?
        do {
            guard let options = try parseCLIOptions(Array(CommandLine.arguments.dropFirst())) else {
                print(CLIOptions.help)
                return
            }
            errorBundleIdentifier = options.bundleIdentifier

            // Selecting the exact running process does not read accessibility
            // content. Resolve it first so all startup failures for a valid app
            // invocation can carry the same bundle ID and PID attestation.
            let runner = try SensorRunner(options: options)
            errorProcessIdentifier = runner.targetProcessIdentifier

            guard AXIsProcessTrusted() else {
                throw SensorFailure(
                    "accessibility_permission_required",
                    "Accessibility permission is required. Grant it manually, then run the command again."
                )
            }
            let runtimePlan = SensorRuntimePlan(textOnly: options.textOnly)
            if runtimePlan.requiresInputMonitoringPermission {
                guard CGPreflightListenEventAccess() else {
                    throw SensorFailure(
                        "input_monitoring_permission_required",
                        "Input Monitoring permission is required for the listen-only mouse event tap. Grant it manually, then run the command again."
                    )
                }
            }

            try runner.run()
        } catch let failure as SensorFailure {
            JSONLineWriter().write([
                "type": "error",
                "ok": false,
                "bundle_id": jsonNullable(errorBundleIdentifier),
                "pid": jsonNullable(errorProcessIdentifier),
                "error": [
                    "code": failure.code,
                    "message": failure.message,
                    "details": failure.details,
                ],
            ])
            exit(EXIT_FAILURE)
        } catch {
            JSONLineWriter().write([
                "type": "error",
                "ok": false,
                "bundle_id": jsonNullable(errorBundleIdentifier),
                "pid": jsonNullable(errorProcessIdentifier),
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
