import ApplicationServices
import AppKit
import CoreGraphics
import Darwin
import Foundation
import WDSAppCore
import WDSWhackCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let defaults = UserDefaults.standard
    let ephemeralProcesses = EphemeralProcessRegistry()
    let overlayProcesses = EphemeralProcessRegistry()
    let terminalSocketServer = TerminalSocketServer()
    let previewQueue = DispatchQueue(label: "com.heznpc.WDS.preview", qos: .userInitiated)
    let ownBundleIdentifier = "com.heznpc.WDS"
    let currentDraftAnalyzer = CurrentDraftAnalyzer(maximumCandidates: 1)
    let dictionaryMatcher = DictionaryMatcher()
    let currentDraftCandidatePanel = CurrentDraftCandidatePanel()
    let candidateHotKeys = GlobalCandidateHotKeyController()
    let overlayDurationMilliseconds = 900

    var statusItem: NSStatusItem!
    var menu: NSMenu!
    var statusMenuItem: NSMenuItem?
    var targetMenuItem: NSMenuItem?
    var workspaceObserver: NSObjectProtocol?
    var allowedBundleIdentifiers = Set<String>()
    var autoWatchBundleIdentifiers = Set<String>()
    let dictionaryStore = PhraseDictionaryStore(defaults: .standard)
    var sessionWatchBundleIdentifiers = Set<String>()
    var enabled = false
    var currentTarget: TargetApplication?
    var sensorSession: SensorSession?
    var statusText = "Disabled"
    var latestMotion = MotionSummary.stationary
    var previewSheet: PreviewPhraseSheet?
    var deleteSheet: DeletePhraseSheet?
    var terminalServerReady = false
    var motionCaptureEnabled = false
    var localSessionDetectionEnabled = false
    var localSessionScope: LocalSessionScope?
    var currentLocalDraft: LocalDraftSnapshot?
    var sessionDetectionConsentSheet: SessionDetectionConsentSheet?
    var currentDraftCandidateState: CurrentDraftCandidateState?
    var suppressedCandidateIdentity: CurrentDraftCandidateIdentity?
    var typingDismissedCandidateIdentity: CurrentDraftCandidateIdentity?
    var candidateDebounceIdentifier: UUID?
    var interactionState = InteractionState()
    var accessibilityPermissionPollIdentifier: UUID?
    var lastOverlayOutcome = OverlayOutcome.notTested
    let savingsStore = SavingsStore(defaults: .standard)

    func applicationDidFinishLaunching(_ notification: Notification) {
        enabled = defaults.bool(forKey: Preferences.enabled)
        allowedBundleIdentifiers = Set(defaults.stringArray(forKey: Preferences.allowedBundleIdentifiers) ?? [])
        autoWatchBundleIdentifiers = Set(
            defaults.stringArray(forKey: Preferences.autoWatchBundleIdentifiers) ?? []
        )
        ephemeralProcesses.setAccepting(enabled)
        overlayProcesses.setAccepting(true)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "WDS"
        statusItem.button?.toolTip = "WDS input effect"
        menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        do {
            try terminalSocketServer.start()
            terminalServerReady = true
        } catch {
            terminalServerReady = false
        }

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.frontmostApplicationChanged(app)
        }

        frontmostApplicationChanged(NSWorkspace.shared.frontmostApplication)
        if enabled, !autoWatchBundleIdentifiers.isEmpty, !AXIsProcessTrusted() {
            DispatchQueue.main.async { [weak self] in
                self?.requestAccessibilityPermission()
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        sessionDetectionConsentSheet?.cancel()
        sessionDetectionConsentSheet = nil
        accessibilityPermissionPollIdentifier = nil
        localSessionDetectionEnabled = false
        localSessionScope = nil
        resetLocalSessionData()
        stopSensor(wait: true)
        ephemeralProcesses.cancelAll(wait: true)
        overlayProcesses.cancelAll(wait: true)
        terminalSocketServer.stop()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    func menuDidClose(_ menu: NSMenu) {
        statusMenuItem = nil
        targetMenuItem = nil
    }

    func resumeCandidatePresentationIfPossible() {
        guard let state = currentDraftCandidateState,
              suppressedCandidateIdentity != state.identity,
              typingDismissedCandidateIdentity != state.identity,
              !currentDraftCandidatePanel.isVisible,
              interactionState.isIdle
        else { return }
        scheduleCandidateInspection(for: state, delay: 0.2)
    }

    static func overlayFailureReason(_ failure: OverlayRenderReportFailure) -> String {
        switch failure {
        case .invalidPayload:
            return "렌더 보고 없음"
        case .invalidSchema:
            return "보고 버전 불일치"
        case .incomplete:
            return "완료 신호 없음"
        case .durationMismatch:
            return "재생 시간 불일치"
        case .elapsedOutOfRange:
            return "실행 시간 비정상"
        case .windowNotVisible:
            return "창 표시 확인 실패"
        case .targetOffscreen:
            return "효과 대상이 화면 밖에 있음"
        case .noFramesDrawn:
            return "렌더 프레임 0"
        case .noGlyphContent:
            return "글자 렌더 확인 실패"
        case .noTimerTicks:
            return "효과 타이머 정지"
        }
    }

    static func previewRect(from data: Data) -> PreviewInspectionResult {
        guard data.count <= 8 * 1_024 * 1_024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return .failure("Preview inspection failed")
        }
        guard object["ok"] as? Bool == true else {
            let error = object["error"] as? [String: Any]
            return .failure(bridgeErrorStatus(code: error?["code"] as? String))
        }
        guard let currentValue = object["currentValue"] as? String,
              let range = object["utf16Range"] as? [String: Any],
              let location = integer(range["location"]),
              let length = integer(range["length"]),
              location >= 0,
              length > 0,
              location <= Int.max - length,
              NSMaxRange(NSRange(location: location, length: length)) <= (currentValue as NSString).length
        else { return .failure("Preview inspection failed") }
        let exactPhrase = (currentValue as NSString).substring(
            with: NSRange(location: location, length: length)
        )
        let exact = rectangle(from: object["targetBounds"]).map {
            OverlayRectangle(
                x: Double($0.origin.x),
                y: Double($0.origin.y),
                width: Double($0.width),
                height: Double($0.height)
            )
        }
        let frame = rectangle(from: object["focusedElementFrame"]).map {
            OverlayRectangle(
                x: Double($0.origin.x),
                y: Double($0.origin.y),
                width: Double($0.width),
                height: Double($0.height)
            )
        }
        guard let geometry = OverlayGeometryResolver.resolve(
            exactBounds: exact,
            focusedElementFrame: frame,
            currentValue: currentValue,
            target: exactPhrase,
            utf16Location: location,
            utf16Length: length
        ) else {
            return .failure("Focused phrase has no usable screen bounds")
        }
        let resolved = geometry.rectangle
        return .success(OverlayTarget(
            rectangle: CGRect(
                x: resolved.x,
                y: resolved.y,
                width: resolved.width,
                height: resolved.height
            ),
            isEstimated: geometry.isEstimated
        ))
    }

    static func rectangle(from value: Any?) -> CGRect? {
        guard let dictionary = value as? [String: Any],
              let x = number(dictionary["x"]),
              let y = number(dictionary["y"]),
              let width = number(dictionary["width"]),
              let height = number(dictionary["height"]),
              width > 0, height > 0,
              width <= 10_000, height <= 10_000,
              abs(x) <= 100_000, abs(y) <= 100_000
        else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let result = number.doubleValue
        guard result.isFinite,
              result.rounded(.towardZero) == result,
              result >= Double(Int.min),
              result <= Double(Int.max)
        else { return nil }
        return Int(result)
    }

    static func bridgeErrorStatus(code: String?) -> String {
        switch code {
        case "accessibility_permission_required":
            return "Accessibility permission required"
        case "secure_field_ignored":
            return "Secure fields are never read"
        case "security_metadata_unavailable":
            return "Field security could not be verified"
        case "focused_value_too_large":
            return "Focused draft is too large"
        case "target_not_found":
            return "Exact phrase was not found"
        case "ambiguous_target":
            return "Select one exact occurrence, then retry"
        case "focused_element_not_editable":
            return "Focused element is not editable"
        case "app_focused_element_unavailable", "focused_element_unavailable", "focused_value_unavailable":
            return "Focus the target input, then retry"
        case "target_app_not_running":
            return "Target app is no longer running"
        case "target_app_not_frontmost", "focused_process_unavailable", "focused_process_mismatch":
            return "Target app or focus changed"
        default:
            return "Preview inspection failed"
        }
    }

    func motionSummary(from dictionary: [String: Any]) -> MotionSummary {
        MotionSummary(
            direction: dictionary["direction"] as? String ?? "stationary",
            speed: (dictionary["average_speed_points_per_second"] as? NSNumber)?.doubleValue ?? 0,
            distance: (dictionary["distance_points"] as? NSNumber)?.doubleValue ?? 0
        )
    }

    func sensorErrorStatus(code: String?) -> String {
        switch code {
        case "accessibility_permission_required":
            return "Accessibility permission required"
        case "input_monitoring_permission_required", "mouse_event_tap_unavailable":
            return "Input Monitoring permission required"
        case "target_app_not_running":
            return "Target app is no longer running"
        default:
            return "Sensor failed"
        }
    }

    func helperURL(named name: String) -> URL? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    func displayName(for bundleIdentifier: String) -> String {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first,
           let name = running.localizedName {
            return name
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
           let name = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String {
            return name
        }
        return bundleIdentifier
    }

    func setStatus(_ status: String) {
        statusText = status
        let marker: String
        if currentDraftCandidatePanel.isVisible {
            marker = "!"
        } else if localSessionDetectionEnabled {
            marker = "●"
        } else if enabled {
            marker = "◐"
        } else {
            marker = "○"
        }
        statusItem?.button?.title = "WDS \(marker)"
        statusItem?.button?.toolTip = "WDS — \(status)"
        statusMenuItem?.title = "상태: \(status)"
    }
}

private let application = NSApplication.shared
application.setActivationPolicy(.accessory)
private let delegate = AppDelegate()
application.delegate = delegate
withExtendedLifetime(delegate) {
    application.run()
}
