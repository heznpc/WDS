import ApplicationServices
import AppKit
import CoreGraphics
import Darwin
import Foundation
import Inertbox
import UniformTypeIdentifiers
import WDSAppCore
import WDSTerminalAdapterCore
import WDSWhackCore

private enum Preferences {
    static let allowedBundleIdentifiers = "wds.allowedBundleIdentifiers"
    static let autoWatchBundleIdentifiers = "wds.autoWatchBundleIdentifiers.v1"
}

private struct TargetApplication {
    let application: NSRunningApplication
    let bundleIdentifier: String
    let name: String

    init?(_ application: NSRunningApplication) {
        guard let bundleIdentifier = application.bundleIdentifier, !bundleIdentifier.isEmpty else {
            return nil
        }
        self.application = application
        self.bundleIdentifier = bundleIdentifier
        name = application.localizedName ?? bundleIdentifier
    }

    var processIdentifier: pid_t { application.processIdentifier }
}

private struct LocalSessionScope {
    let bundleIdentifier: String
    let processIdentifier: pid_t

    func matches(_ target: TargetApplication) -> Bool {
        bundleIdentifier == target.bundleIdentifier
            && processIdentifier == target.processIdentifier
    }
}

private struct MotionSummary {
    let direction: String
    let speed: Double
    let distance: Double

    static let stationary = MotionSummary(direction: "stationary", speed: 0, distance: 0)

    init(direction: String, speed: Double, distance: Double) {
        let allowedDirections = Set([
            "stationary", "north", "northeast", "east", "southeast",
            "south", "southwest", "west", "northwest",
        ])
        self.direction = allowedDirections.contains(direction) ? direction : "stationary"
        self.speed = min(12_000, max(0, speed.isFinite ? speed : 0))
        self.distance = min(8_000, max(0, distance.isFinite ? distance : 0))
    }
}

private struct JSONLineBatch {
    let objects: [[String: Any]]
    let overflowed: Bool
}

private final class JSONLineParser {
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

private final class SensorSession {
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

private enum EphemeralLaunchError: Error {
    case cancelled
}

private struct OverlayTarget {
    let rectangle: CGRect
    let isEstimated: Bool
}

private enum PreviewInspectionResult {
    case success(OverlayTarget)
    case failure(String)
}

private enum DeleteInspectionResult {
    case success(SafeDeleteInspection)
    case failure(String)
}

private enum DeleteExecutionResult {
    case success
    case failure(String)
}

private enum CandidateInspectionResult {
    case success(CGRect)
    case failure(String)
}

private enum OverlayOutcome {
    case notTested
    case rendering
    case verified(frames: Int, elapsedMilliseconds: Int)
    case failed(String)

    var menuTitle: String {
        switch self {
        case .notTested:
            return "최근 효과: 아직 확인하지 않음"
        case .rendering:
            return "최근 효과: 렌더 중…"
        case .verified(let frames, let elapsedMilliseconds):
            return "최근 효과: 렌더 확인 • \(frames)프레임 • \(elapsedMilliseconds)ms"
        case .failed(let reason):
            return "최근 효과: 확인 실패 • \(reason)"
        }
    }
}

private final class EphemeralProcessRegistry {
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

private final class PreviewPhraseSheet {
    private var anchorWindow: NSWindow?
    private var alert: NSAlert?
    private var phraseField: NSTextField?
    private var completion: ((String?) -> Void)?

    func present(for targetName: String, completion: @escaping (String?) -> Void) {
        self.completion = completion

        let anchor = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 84),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        anchor.title = "WDS Preview"
        anchor.isReleasedWhenClosed = false
        let label = NSTextField(labelWithString: "Preview target: \(targetName)")
        label.frame = NSRect(x: 20, y: 31, width: 420, height: 22)
        label.alignment = .center
        anchor.contentView?.addSubview(label)

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 390, height: 24))
        field.placeholderString = "Exact phrase in the focused input"

        let alert = NSAlert()
        alert.messageText = "Preview focused input effect"
        alert.informativeText = "Enter the exact phrase once. WDS will inspect its Accessibility range and play a visual overlay only—it will not delete or submit text."
        alert.accessoryView = field
        alert.addButton(withTitle: "Preview")
        alert.addButton(withTitle: "Cancel")

        anchorWindow = anchor
        self.alert = alert
        phraseField = field

        NSApp.activate(ignoringOtherApps: true)
        anchor.center()
        anchor.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self, weak anchor] in
            guard let self, let anchor else { return }
            alert.beginSheetModal(for: anchor) { [weak self] response in
                self?.finish(response: response)
            }
        }
    }

    func cancel() {
        guard let anchorWindow, let alert else { return }
        anchorWindow.endSheet(alert.window, returnCode: .cancel)
    }

    private func finish(response: NSApplication.ModalResponse) {
        let value = phraseField?.stringValue ?? ""
        phraseField?.stringValue = ""
        let result = response == .alertFirstButtonReturn && !value.isEmpty ? value : nil
        anchorWindow?.orderOut(nil)
        anchorWindow = nil
        alert = nil
        phraseField = nil
        let completion = completion
        self.completion = nil
        completion?(result)
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let defaults = UserDefaults.standard
    private var ephemeralProcesses = EphemeralProcessRegistry()
    private var sourceImportProcesses = EphemeralProcessRegistry()
    private let overlayProcesses = EphemeralProcessRegistry()
    private let terminalReview = TerminalReviewController()
    private var terminalInteraction: InteractionToken?
    private lazy var terminalSocketServer = TerminalSocketServer { [weak self] request in
        self?.terminalReview.resolve(request) ?? TerminalResolveResponse(requestID: request.requestID, decision: .passThrough)
    }
    private let previewQueue = DispatchQueue(label: "com.heznpc.WDS.preview", qos: .userInitiated)
    private let ownBundleIdentifier = "com.heznpc.WDS"
    private let currentDraftAnalyzer = CurrentDraftAnalyzer(maximumCandidates: 1, includesCorrections: true)
    private let currentDraftCandidatePanel = CurrentDraftCandidatePanel()
    private let candidateHotKeys = GlobalCandidateHotKeyController()
    private let overlayDurationMilliseconds = 900

    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var statusMenuItem: NSMenuItem?
    private var targetMenuItem: NSMenuItem?
    private var workspaceObserver: NSObjectProtocol?
    private var allowedBundleIdentifiers = Set<String>()
    private var autoWatchBundleIdentifiers = Set<String>()
    private var sessionWatchBundleIdentifiers = Set<String>()
    private var features = FeatureSettings()
    private var inputCleanupEnabled: Bool { features.inputCleanupEnabled }
    private var sourceSeparationEnabled: Bool { features.sourceSeparationEnabled }
    private var currentTarget: TargetApplication?
    private var sensorSession: SensorSession?
    private var statusText = "Disabled"
    private var latestMotion = MotionSummary.stationary
    private var previewSheet: PreviewPhraseSheet?
    private var deleteSheet: DeletePhraseSheet?
    private var sourceImportPanel: NSOpenPanel?
    private var terminalServerReady = false
    private var motionCaptureEnabled = false
    private var localSessionDetectionEnabled = false
    private var localSessionScope: LocalSessionScope?
    private var currentLocalDraft: CurrentDraftSnapshot?
    private var sessionDetectionConsentSheet: SessionDetectionConsentSheet?
    private var candidateTracker = CurrentDraftCandidateTracker()
    private var candidatePresentation = CandidateHotKeyLifecycle()
    private var interactionState = InteractionState()
    private var accessibilityPermissionPollIdentifier: UUID?
    private var lastOverlayOutcome = OverlayOutcome.notTested

    func applicationDidFinishLaunching(_ notification: Notification) {
        features = FeatureSettings(defaults: defaults)
        features.save(to: defaults)
        allowedBundleIdentifiers = Set(defaults.stringArray(forKey: Preferences.allowedBundleIdentifiers) ?? [])
        autoWatchBundleIdentifiers = Set(
            defaults.stringArray(forKey: Preferences.autoWatchBundleIdentifiers) ?? []
        )
        ephemeralProcesses.setAccepting(inputCleanupEnabled)
        sourceImportProcesses.setAccepting(sourceSeparationEnabled)
        overlayProcesses.setAccepting(true)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "WDS"
        statusItem.button?.toolTip = "WDS input effect"
        menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        terminalReview.onBegin = { [weak self] in
            guard let self, self.inputCleanupEnabled,
                  let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                  self.allowedBundleIdentifiers.contains(bundle) else { return false }
            self.interactionState.cancel(.candidateInspection)
            self.dismissCurrentDraftCandidate()
            guard let token = self.interactionState.begin(.delete) else { return false }
            self.terminalInteraction = token
            self.setStatus("터미널 후보를 확인하세요 • 승인 전에는 그대로 유지됩니다")
            return true
        }
        terminalReview.onEnd = { [weak self] in
            guard let self, let token = self.terminalInteraction else { return }
            self.interactionState.finish(token)
            self.terminalInteraction = nil
            self.setStatus("터미널 검토를 마쳤습니다")
            self.resumeCandidatePresentationIfPossible()
        }

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
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        sourceImportPanel?.cancel(nil)
        sourceImportPanel = nil
        sessionDetectionConsentSheet?.cancel()
        sessionDetectionConsentSheet = nil
        accessibilityPermissionPollIdentifier = nil
        localSessionDetectionEnabled = false
        localSessionScope = nil
        resetLocalSessionData()
        stopSensor(wait: true)
        ephemeralProcesses.cancelAll(wait: true)
        sourceImportProcesses.cancelAll(wait: true)
        overlayProcesses.cancelAll(wait: true)
        terminalReview.cancel()
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

    private func rebuildMenu() {
        menu.removeAllItems()

        let cleanupToggle = NSMenuItem(title: "입력 정리", action: #selector(toggleInputCleanup), keyEquivalent: "")
        cleanupToggle.target = self
        cleanupToggle.state = inputCleanupEnabled ? .on : .off
        cleanupToggle.toolTip = "군더더기 삭제·표기 교정을 제안합니다. 승인한 구간만 바뀝니다"
        menu.addItem(cleanupToggle)

        let sourceToggle = NSMenuItem(title: "출처 구분", action: #selector(toggleSourceSeparation), keyEquivalent: "")
        sourceToggle.target = self
        sourceToggle.state = sourceSeparationEnabled ? .on : .off
        sourceToggle.toolTip = "가져오는 다른 세션의 의견에 출처 경계와 비판적 검토 지침을 붙입니다"
        menu.addItem(sourceToggle)
        menu.addItem(.separator())

        let currentAllowed = currentTarget.map {
            allowedBundleIdentifiers.contains($0.bundleIdentifier)
        } == true
        let scopeMatchesCurrent = currentTarget.map {
            localSessionScope?.matches($0) == true && localSessionDetectionEnabled
        } == true
        let currentAutoWatch = currentTarget.map {
            autoWatchBundleIdentifiers.contains($0.bundleIdentifier)
        } == true

        let primaryTitle: String
        if !inputCleanupEnabled {
            primaryTitle = "입력 정리 꺼짐"
        } else if currentAutoWatch, let currentTarget {
            primaryTitle = "\(currentTarget.name) 자동 감시 해제"
        } else if !AXIsProcessTrusted() {
            primaryTitle = "WDS 텍스트 접근 권한 부여…"
        } else if let currentTarget {
            primaryTitle = scopeMatchesCurrent
                ? "\(currentTarget.name) 입력 정리 중지"
                : "\(currentTarget.name) 입력 정리 시작…"
        } else {
            primaryTitle = "입력할 앱을 먼저 선택하세요"
        }
        let primaryAction = NSMenuItem(
            title: primaryTitle,
            action: #selector(toggleWDSForCurrentApplication),
            keyEquivalent: ""
        )
        primaryAction.target = self
        primaryAction.state = inputCleanupEnabled && (scopeMatchesCurrent || currentAutoWatch) ? .on : .off
        primaryAction.isEnabled = inputCleanupEnabled && currentTarget != nil
            && !interactionState.isActive(.preview)
            && !interactionState.isActive(.delete)
            && !interactionState.isActive(.sourceImport)
            && sessionDetectionConsentSheet == nil
        menu.addItem(primaryAction)

        let primaryNote = NSMenuItem(
            title: "현재 초안만 로컬 분석 • AI 0회 • 자동 전송 없음",
            action: nil,
            keyEquivalent: ""
        )
        primaryNote.isEnabled = false
        menu.addItem(primaryNote)
        let usageNote = NSMenuItem(
            title: "문장 입력 → 잠시 멈춤 → ‘날리기’ 또는 ‘고치기’",
            action: nil,
            keyEquivalent: ""
        )
        usageNote.isEnabled = false
        menu.addItem(usageNote)
        menu.addItem(.separator())

        for (title, action) in [
            ("다른 세션 의견 붙여넣기", #selector(pasteExternalOpinion)),
            ("선택한 내용을 다른 세션 의견으로 표시", #selector(markSelectedOpinion)),
            ("텍스트 파일을 외부 의견으로 가져오기…", #selector(importExternalOpinionFile)),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = sourceSeparationEnabled && currentTarget != nil && interactionState.isIdle
            menu.addItem(item)
        }

        let effectTest = NSMenuItem(
            title: interactionState.isActive(.overlay) ? "효과 렌더 중…" : "효과 테스트",
            action: #selector(testEffect),
            keyEquivalent: ""
        )
        effectTest.target = self
        effectTest.isEnabled = interactionState.isIdle
            && !candidatePresentation.isShowing
        effectTest.toolTip = "권한이나 입력창 없이 화면 중앙에서 삭제 효과만 확인합니다"
        menu.addItem(effectTest)

        let effectOutcome = NSMenuItem(
            title: lastOverlayOutcome.menuTitle,
            action: nil,
            keyEquivalent: ""
        )
        effectOutcome.isEnabled = false
        menu.addItem(effectOutcome)
        menu.addItem(.separator())

        let targetTitle: String
        if let currentTarget {
            targetTitle = "Current: \(currentTarget.name) (\(currentTarget.bundleIdentifier))"
        } else {
            targetTitle = "Current: no supported frontmost app"
        }
        let targetItem = NSMenuItem(title: targetTitle, action: nil, keyEquivalent: "")
        targetItem.isEnabled = false
        targetMenuItem = targetItem
        menu.addItem(targetItem)

        let statusItem = NSMenuItem(title: "상태: \(statusText)", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        statusMenuItem = statusItem
        menu.addItem(statusItem)
        menu.addItem(.separator())

        let allowTitle = currentAllowed ? "Current App Is Allowed" : "Allow Current Frontmost App"
        let allowItem = NSMenuItem(title: allowTitle, action: #selector(allowCurrentApplication), keyEquivalent: "")
        allowItem.target = self
        allowItem.isEnabled = currentTarget != nil && !currentAllowed
        menu.addItem(allowItem)

        let allowedItem = NSMenuItem(title: "Allowed Apps", action: nil, keyEquivalent: "")
        let allowedMenu = NSMenu()
        if allowedBundleIdentifiers.isEmpty {
            let empty = NSMenuItem(title: "No allowed apps", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            allowedMenu.addItem(empty)
        } else {
            for bundleIdentifier in allowedBundleIdentifiers.sorted() {
                let name = displayName(for: bundleIdentifier)
                let remove = NSMenuItem(
                    title: "Remove \(name) (\(bundleIdentifier))",
                    action: #selector(removeAllowedApplication(_:)),
                    keyEquivalent: ""
                )
                remove.target = self
                remove.representedObject = bundleIdentifier
                allowedMenu.addItem(remove)
            }
        }
        allowedItem.submenu = allowedMenu
        menu.addItem(allowedItem)

        let assistanceItem = NSMenuItem(title: "Input Assistance", action: nil, keyEquivalent: "")
        let assistanceMenu = NSMenu()
        let detectionTitle: String
        if scopeMatchesCurrent {
            detectionTitle = "Watching Current Draft (This App)"
        } else if localSessionDetectionEnabled {
            detectionTitle = "Move Current-Draft Watch to This App…"
        } else {
            detectionTitle = "Watch Current Draft in This App…"
        }
        let detectionToggle = NSMenuItem(
            title: detectionTitle,
            action: #selector(toggleLocalSessionDetection),
            keyEquivalent: ""
        )
        detectionToggle.target = self
        detectionToggle.state = scopeMatchesCurrent ? .on : .off
        detectionToggle.isEnabled = inputCleanupEnabled && currentAllowed
        detectionToggle.toolTip = "Current draft only • this launch • local rules • no AI or network"
        assistanceMenu.addItem(detectionToggle)

        let privacyNote = NSMenuItem(
            title: "현재 초안만 • AI 0회 • 초안 저장 안 함",
            action: nil,
            keyEquivalent: ""
        )
        privacyNote.isEnabled = false
        assistanceMenu.addItem(privacyNote)
        assistanceMenu.addItem(.separator())

        if let candidate = candidateTracker.state {
            if candidateTracker.isKept(candidate.identity) {
                let candidateItem = NSMenuItem(
                    title: "이 입력창에서 유지: \u{201c}\(candidate.displayPhrase)\u{201d}",
                    action: nil,
                    keyEquivalent: ""
                )
                candidateItem.isEnabled = false
                assistanceMenu.addItem(candidateItem)
            } else if candidatePresentation.isShowing {
                let shortcutsAvailable = candidatePresentation.keyboardShortcutsAvailable
                let keepItem = NSMenuItem(
                    title: shortcutsAvailable
                        ? "후보 유지: \u{201c}\(candidate.displayPhrase)\u{201d}  ⌃⌘K"
                        : "후보 유지: \u{201c}\(candidate.displayPhrase)\u{201d}",
                    action: #selector(keepCurrentDraftCandidateFromMenu),
                    keyEquivalent: ""
                )
                keepItem.target = self
                assistanceMenu.addItem(keepItem)

                let approveItem = NSMenuItem(
                    title: shortcutsAvailable
                        ? "후보 날리기: \u{201c}\(candidate.displayPhrase)\u{201d}  ⌃⌘⌫"
                        : "후보 날리기: \u{201c}\(candidate.displayPhrase)\u{201d}",
                    action: #selector(approveCurrentDraftCandidateFromMenu),
                    keyEquivalent: ""
                )
                approveItem.target = self
                assistanceMenu.addItem(approveItem)
            } else {
                let candidateItem = NSMenuItem(
                    title: "후보 다시 보기: \u{201c}\(candidate.displayPhrase)\u{201d}",
                    action: #selector(showCurrentDraftCandidate),
                    keyEquivalent: ""
                )
                candidateItem.target = self
                candidateItem.isEnabled = interactionState.isIdle
                assistanceMenu.addItem(candidateItem)
            }
        } else {
            let noSuggestion = NSMenuItem(
                title: scopeMatchesCurrent
                    ? "No conservative candidate in the current draft"
                    : "Current-draft watch is off for this app",
                action: nil,
                keyEquivalent: ""
            )
            noSuggestion.isEnabled = false
            assistanceMenu.addItem(noSuggestion)
        }

        let forget = NSMenuItem(
            title: "Stop Watching & Forget Current Draft",
            action: #selector(forgetLocalSessionData),
            keyEquivalent: ""
        )
        forget.target = self
        forget.isEnabled = localSessionDetectionEnabled || currentLocalDraft != nil
        assistanceMenu.addItem(forget)
        assistanceMenu.addItem(.separator())

        let remote = NSMenuItem(
            title: "AI Context Checks: Off • 0 calls • 0 tokens",
            action: nil,
            keyEquivalent: ""
        )
        remote.isEnabled = false
        assistanceMenu.addItem(remote)
        assistanceItem.submenu = assistanceMenu
        menu.addItem(assistanceItem)
        menu.addItem(.separator())

        let preview = NSMenuItem(title: "Preview Focused Input Effect…", action: #selector(previewFocusedInput), keyEquivalent: "")
        preview.target = self
        preview.isEnabled = inputCleanupEnabled && currentAllowed
            && interactionState.isIdle
        menu.addItem(preview)

        let delete = NSMenuItem(
            title: "Whack & Delete Exact Phrase…",
            action: #selector(deleteExactPhrase),
            keyEquivalent: ""
        )
        delete.target = self
        delete.isEnabled = inputCleanupEnabled && currentAllowed
            && interactionState.isIdle
        menu.addItem(delete)
        menu.addItem(.separator())

        let accessibilityPermission = NSMenuItem(
            title: AXIsProcessTrusted()
                ? "Text Accessibility Permission: Granted"
                : "Grant Text Accessibility Permission…",
            action: #selector(requestAccessibilityPermission),
            keyEquivalent: ""
        )
        accessibilityPermission.target = self
        accessibilityPermission.state = AXIsProcessTrusted() ? .on : .off
        accessibilityPermission.isEnabled = !AXIsProcessTrusted()
        menu.addItem(accessibilityPermission)

        let mousePermission = NSMenuItem(
            title: "Request Optional Mouse Effect Permission…",
            action: #selector(requestMouseEffectPermission),
            keyEquivalent: ""
        )
        mousePermission.target = self
        menu.addItem(mousePermission)

        let motionCapture = NSMenuItem(
            title: localSessionDetectionEnabled
                ? "Mouse Motion Effects Paused During Draft Watch"
                : "Use Recent Mouse Motion for Effects (This Launch)",
            action: #selector(toggleMotionCapture),
            keyEquivalent: ""
        )
        motionCapture.target = self
        motionCapture.state = motionCaptureEnabled ? .on : .off
        motionCapture.isEnabled = inputCleanupEnabled && !localSessionDetectionEnabled
        menu.addItem(motionCapture)
        menu.addItem(.separator())

        for title in [
            "Native/browser input: macOS Accessibility (AX)",
            terminalServerReady
                ? "Zsh: 명시적 검토 후 승인한 구간만 삭제"
                : "Terminal: local transport unavailable",
            "Interactive CLI editors: semantic hook required",
        ] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit WDS", action: #selector(quitApplication), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func toggleInputCleanup() {
        features.inputCleanupEnabled.toggle()
        features.save(to: defaults)
        if inputCleanupEnabled {
            // Queued work retains the cancelled registry from its old opt-in.
            ephemeralProcesses = EphemeralProcessRegistry()
            ephemeralProcesses.setAccepting(true)
            activateAutomaticDraftWatchIfNeeded()
        } else {
            terminalReview.cancel()
            disableLocalSessionDetection(restartSensor: false)
            previewSheet?.cancel()
            deleteSheet?.cancel()
            interactionState.cancel(.preview)
            interactionState.cancel(.delete)
            ephemeralProcesses.cancelAll(wait: false)
        }
        reconcileSensor()
    }

    @objc private func toggleSourceSeparation() {
        features.sourceSeparationEnabled.toggle()
        features.save(to: defaults)
        if sourceSeparationEnabled {
            sourceImportProcesses = EphemeralProcessRegistry()
            sourceImportProcesses.setAccepting(true)
        } else {
            interactionState.cancel(.sourceImport)
            sourceImportPanel?.cancel(nil)
            sourceImportPanel = nil
            sourceImportProcesses.cancelAll(wait: false)
        }
        setStatus(sourceSeparationEnabled ? "출처 구분 켜짐" : "출처 구분 꺼짐")
        resumeCandidatePresentationIfPossible()
    }

    @objc private func toggleWDSForCurrentApplication() {
        guard inputCleanupEnabled, let target = currentTarget else { return }

        if autoWatchBundleIdentifiers.remove(target.bundleIdentifier) != nil {
            sessionWatchBundleIdentifiers.remove(target.bundleIdentifier)
            persistAllowlist()
            if localSessionScope?.matches(target) == true {
                disableLocalSessionDetection(restartSensor: true)
            } else {
                reconcileSensor()
            }
            setStatus("\(target.name) 자동 감시 해제 • 초안 해제")
            return
        }

        if localSessionDetectionEnabled, localSessionScope?.matches(target) == true {
            sessionWatchBundleIdentifiers.remove(target.bundleIdentifier)
            disableLocalSessionDetection(restartSensor: true)
            setStatus("\(target.name) 감시 중지 • 초안 해제")
            return
        }

        guard AXIsProcessTrusted() else {
            requestAccessibilityPermission()
            setStatus("손쉬운 사용 권한을 허용한 뒤 입력 정리 시작을 다시 누르세요")
            return
        }
        presentCurrentDraftWatchConsent(
            for: target,
            grantPersistentAccessOnAccept: true
        )
    }

    @objc private func allowCurrentApplication() {
        guard let currentTarget else { return }
        allowedBundleIdentifiers.insert(currentTarget.bundleIdentifier)
        persistAllowlist()
        reconcileSensor()
    }

    @objc private func removeAllowedApplication(_ sender: NSMenuItem) {
        guard let bundleIdentifier = sender.representedObject as? String else { return }
        allowedBundleIdentifiers.remove(bundleIdentifier)
        autoWatchBundleIdentifiers.remove(bundleIdentifier)
        sessionWatchBundleIdentifiers.remove(bundleIdentifier)
        if localSessionScope?.bundleIdentifier == bundleIdentifier {
            disableLocalSessionDetection(restartSensor: false)
        }
        persistAllowlist()
        reconcileSensor()
    }

    @objc private func toggleLocalSessionDetection() {
        guard inputCleanupEnabled,
              let target = currentTarget,
              allowedBundleIdentifiers.contains(target.bundleIdentifier)
        else { return }

        if localSessionDetectionEnabled, localSessionScope?.matches(target) == true {
            sessionWatchBundleIdentifiers.remove(target.bundleIdentifier)
            if autoWatchBundleIdentifiers.contains(target.bundleIdentifier) {
                autoWatchBundleIdentifiers.remove(target.bundleIdentifier)
                persistAllowlist()
            }
            disableLocalSessionDetection(restartSensor: true)
            setStatus("현재 초안 감시 중지 • 초안 해제")
            return
        }

        presentCurrentDraftWatchConsent(
            for: target,
            grantPersistentAccessOnAccept: false
        )
    }

    private func presentCurrentDraftWatchConsent(
        for target: TargetApplication,
        grantPersistentAccessOnAccept: Bool
    ) {
        sessionDetectionConsentSheet?.cancel()
        let sheet = SessionDetectionConsentSheet()
        sessionDetectionConsentSheet = sheet
        sheet.present(
            for: target.name,
            automaticallyResume: grantPersistentAccessOnAccept
        ) { [weak self] accepted in
            guard let self else { return }
            self.sessionDetectionConsentSheet = nil
            guard accepted, self.inputCleanupEnabled, !target.application.isTerminated else {
                _ = target.application.activate(options: [.activateIgnoringOtherApps])
                self.setStatus("현재 초안 감시 상태를 바꾸지 않았습니다")
                return
            }

            if grantPersistentAccessOnAccept {
                self.allowedBundleIdentifiers.insert(target.bundleIdentifier)
                self.autoWatchBundleIdentifiers.insert(target.bundleIdentifier)
                self.persistAllowlist()
            } else {
                self.sessionWatchBundleIdentifiers.insert(target.bundleIdentifier)
            }
            guard self.inputCleanupEnabled,
                  AXIsProcessTrusted(),
                  self.allowedBundleIdentifiers.contains(target.bundleIdentifier) else {
                _ = target.application.activate(options: [.activateIgnoringOtherApps])
                self.setStatus("입력 정리 시작 실패: 권한 또는 앱 허용 상태를 확인하세요")
                return
            }

            self.disableLocalSessionDetection(restartSensor: false)
            self.localSessionDetectionEnabled = true
            self.localSessionScope = LocalSessionScope(
                bundleIdentifier: target.bundleIdentifier,
                processIdentifier: target.processIdentifier
            )
            _ = target.application.activate(options: [.activateIgnoringOtherApps])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self,
                      self.inputCleanupEnabled,
                      self.localSessionScope?.matches(target) == true else { return }
                self.reconcileSensor()
                self.setStatus("현재 초안 감시 중 • 로컬 • 토큰 0")
            }
        }
    }

    @objc private func showCurrentDraftCandidate() {
        guard let ticket = candidateTracker.reshowInspection(
            engineEnabled: inputCleanupEnabled,
            isIdle: interactionState.isIdle
        ) else { return }
        armCandidateInspection(ticket, delay: 0)
    }

    @objc private func keepCurrentDraftCandidateFromMenu() {
        guard candidatePresentation.isShowing,
              let identity = candidateTracker.state?.identity else { return }
        keepCurrentDraftCandidate(identity)
    }

    @objc private func approveCurrentDraftCandidateFromMenu() {
        guard candidatePresentation.isShowing,
              let identity = candidateTracker.state?.identity else { return }
        approveCurrentDraftCandidate(identity)
    }

    @objc private func forgetLocalSessionData() {
        if let bundleIdentifier = localSessionScope?.bundleIdentifier,
           autoWatchBundleIdentifiers.remove(bundleIdentifier) != nil {
            persistAllowlist()
        }
        if let bundleIdentifier = localSessionScope?.bundleIdentifier {
            sessionWatchBundleIdentifiers.remove(bundleIdentifier)
        }
        disableLocalSessionDetection(restartSensor: true)
        setStatus("현재 초안 감시 중지 • 초안 해제")
    }

    private func disableLocalSessionDetection(restartSensor: Bool) {
        sessionDetectionConsentSheet?.cancel()
        sessionDetectionConsentSheet = nil
        localSessionDetectionEnabled = false
        localSessionScope = nil
        resetLocalSessionData()
        stopSensor(wait: false)
        if restartSensor { reconcileSensor() }
    }

    private func resetLocalSessionData() {
        clearCurrentLocalDraft()
    }

    private func dismissCurrentDraftCandidate() {
        candidateHotKeys.deactivate()
        currentDraftCandidatePanel.dismiss()
        candidatePresentation.didHide()
    }

    private func clearCurrentLocalDraft() {
        currentLocalDraft = nil
        interactionState.cancel(.candidateInspection)
        candidateTracker.reset()
        dismissCurrentDraftCandidate()
    }

    private func shouldCaptureRawText(for target: TargetApplication) -> Bool {
        localSessionDetectionEnabled && localSessionScope?.matches(target) == true
    }

    private func shouldUseTextOnlySensor(for target: TargetApplication) -> Bool {
        shouldCaptureRawText(for: target) || !motionCaptureEnabled
    }

    private func currentDraftForCurrentTarget() -> CurrentDraftSnapshot? {
        guard let target = currentTarget,
              shouldCaptureRawText(for: target),
              let draft = currentLocalDraft,
              draft.bundleIdentifier == target.bundleIdentifier,
              draft.processIdentifier == target.processIdentifier,
              sensorSession?.focusEpoch == draft.focusEpoch else { return nil }
        return draft
    }

    private func refreshCurrentDraftCandidate() {
        let outcome = candidateTracker.refresh(
            with: currentDraftForCurrentTarget(),
            analyzer: currentDraftAnalyzer,
            isPanelVisible: candidatePresentation.isShowing
        )

        switch outcome {
        case .cleared:
            interactionState.cancel(.candidateInspection)
            dismissCurrentDraftCandidate()
            if localSessionDetectionEnabled {
                setStatus("현재 초안 감시 중 • 안전한 후보 없음")
            }
        case .unchanged:
            break
        case .hiddenWhileTyping:
            dismissCurrentDraftCandidate()
            setStatus("계속 입력하여 후보 숨김 • 메뉴에서 다시 볼 수 있습니다")
        case .alreadyKept(let state):
            interactionState.cancel(.candidateInspection)
            dismissCurrentDraftCandidate()
            setStatus("\u{201c}\(state.displayPhrase)\u{201d} 유지 • 이 입력창에서는 다시 묻지 않음")
        case .readyToInspect(let state):
            interactionState.cancel(.candidateInspection)
            dismissCurrentDraftCandidate()
            guard let ticket = candidateTracker.scheduleInspection(
                for: state.identity,
                engineEnabled: inputCleanupEnabled,
                isIdle: interactionState.isIdle
            ) else { return }
            armCandidateInspection(
                ticket,
                delay: CurrentDraftCandidateTracker.typingDebounce
            )
        }
    }

    /// Arms the debounce timer for an already-granted inspection ticket.
    ///
    /// The ticket is re-checked when the timer fires, so a newer keystroke that
    /// took a fresh ticket silently retires this one.
    private func armCandidateInspection(
        _ ticket: CandidateInspectionTicket,
        delay: TimeInterval
    ) {
        let identity = ticket.identity
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  self.candidateTracker.canBeginInspection(ticket),
                  self.interactionState.isIdle,
                  let target = self.currentTarget,
                  target.bundleIdentifier == identity.bundleIdentifier,
                  target.processIdentifier == identity.processIdentifier,
                  self.editTargetIsReady(target),
                  let state = self.candidateTracker.state,
                  state.identity == identity
            else { return }
            self.candidateTracker.beginInspection(ticket)
            self.inspectForCandidate(
                ticket: ticket,
                state: state,
                target: target
            )
        }
    }

    private func inspectForCandidate(
        ticket: CandidateInspectionTicket,
        state: CurrentDraftCandidateState,
        target: TargetApplication
    ) {
        guard let executableURL = helperURL(named: "wds-ax-bridge") else {
            setStatus("후보 위치 도구가 없습니다")
            return
        }
        guard let interaction = interactionState.begin(.candidateInspection) else { return }

        let registry = ephemeralProcesses
        previewQueue.async { [weak self] in
            let process = Process()
            let inputPipe = Pipe()
            let outputPipe = Pipe()
            process.executableURL = executableURL
            process.arguments = ["inspect", "--target-stdin", "--bundle-id", target.bundleIdentifier]
            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            process.standardError = FileHandle.nullDevice
            var launchedIdentifier: UUID?
            defer {
                try? inputPipe.fileHandleForWriting.close()
                if process.isRunning { process.terminate() }
                if let launchedIdentifier { registry.finish(launchedIdentifier) }
            }

            let result: CandidateInspectionResult
            do {
                launchedIdentifier = try registry.start(process)
                try inputPipe.fileHandleForWriting.write(
                    contentsOf: Data(state.candidate.originalText.utf8)
                )
                try inputPipe.fileHandleForWriting.close()
                let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                switch Self.previewRect(from: output) {
                case .success(let overlayTarget):
                    result = .success(overlayTarget.rectangle)
                case .failure(let status):
                    result = .failure(status)
                }
            } catch {
                result = .failure("Candidate inspection was cancelled")
            }

            DispatchQueue.main.async { [weak self] in
                self?.finishCandidateInspection(
                    result,
                    ticket: ticket,
                    state: state,
                    target: target,
                    interaction: interaction
                )
            }
        }
    }

    private func finishCandidateInspection(
        _ result: CandidateInspectionResult,
        ticket: CandidateInspectionTicket,
        state: CurrentDraftCandidateState,
        target: TargetApplication,
        interaction: InteractionToken
    ) {
        guard interactionState.finish(interaction) else { return }
        guard inputCleanupEnabled,
              candidateTracker.canPresent(
                  ticket,
                  latestSnapshot: currentDraftForCurrentTarget(),
                  analyzer: currentDraftAnalyzer
              ),
              currentTarget?.processIdentifier == target.processIdentifier,
              editTargetIsReady(target)
        else { return }

        switch result {
        case .failure(let status):
            setStatus(status)
        case .success(let rectangle):
            let keyboardShortcutsAvailable = candidateHotKeys.activate(
                onApprove: { [weak self] in
                    self?.approveCurrentDraftCandidate(state.identity)
                },
                onKeep: { [weak self] in
                    self?.keepCurrentDraftCandidate(state.identity)
                }
            )
            currentDraftCandidatePanel.present(
                phrase: state.displayPhrase,
                replacement: state.displayReplacement,
                targetBounds: rectangle,
                keyboardShortcutsAvailable: keyboardShortcutsAvailable,
                onApprove: { [weak self] in
                    self?.approveCurrentDraftCandidate(state.identity)
                },
                onKeep: { [weak self] in
                    self?.keepCurrentDraftCandidate(state.identity)
                }
            )
            candidatePresentation.didShow(
                state.identity,
                hotKeysRegistered: keyboardShortcutsAvailable
            )
            let action = state.isCorrection ? "고치기" : "날리기"
            setStatus("후보 \(state.displayPhrase) • \(action)" + (keyboardShortcutsAvailable ? " ⌃⌘⌫" : ""))
        }
    }

    private func keepCurrentDraftCandidate(_ identity: CurrentDraftCandidateIdentity) {
        guard candidateTracker.keep(identity) else {
            dismissCurrentDraftCandidate()
            return
        }
        interactionState.cancel(.candidateInspection)
        dismissCurrentDraftCandidate()
        setStatus("\u{201c}\(identity.originalText.trimmingCharacters(in: .whitespacesAndNewlines))\u{201d} 유지 • 이 입력창에서는 다시 묻지 않음")
    }

    private func approveCurrentDraftCandidate(_ identity: CurrentDraftCandidateIdentity) {
        guard case .proceed(let approvedState) = candidateTracker.approval(
                  of: identity,
                  latestSnapshot: currentDraftForCurrentTarget(),
                  analyzer: currentDraftAnalyzer,
                  engineEnabled: inputCleanupEnabled,
                  isIdle: interactionState.isIdle
              ),
              let target = currentTarget,
              target.bundleIdentifier == identity.bundleIdentifier,
              target.processIdentifier == identity.processIdentifier
        else {
            dismissCurrentDraftCandidate()
            setStatus("후보가 바뀌어 삭제하지 않았습니다")
            resumeCandidatePresentationIfPossible()
            return
        }

        candidateTracker.cancelPendingInspection()
        dismissCurrentDraftCandidate()

        guard let interaction = interactionState.begin(.delete) else { return }
        setStatus("승인한 후보를 다시 확인 중…")
        _ = target.application.activate(options: [.activateIgnoringOtherApps])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self,
                  self.interactionState.owns(interaction),
                  self.editTargetIsReady(target),
                  self.candidateTracker.stillMatches(
                      identity,
                      latestSnapshot: self.currentDraftForCurrentTarget(),
                      analyzer: self.currentDraftAnalyzer
                  ) != nil
            else {
                self?.interactionState.finish(interaction)
                self?.setStatus("후보가 바뀌어 삭제하지 않았습니다")
                self?.resumeCandidatePresentationIfPossible()
                return
            }
            self.inspectForDelete(
                phrase: identity.originalText,
                replacement: approvedState.candidate.replacementText,
                target: target,
                interaction: interaction
            )
        }
    }

    @objc private func pasteExternalOpinion() {
        guard let content = NSPasteboard.general.string(forType: .string), !content.isEmpty else {
            setStatus("클립보드에 다른 세션의 응답을 먼저 복사하세요")
            return
        }
        beginExternalOpinionImport(content: content)
    }

    @objc private func markSelectedOpinion() {
        beginExternalOpinionImport(content: nil)
    }

    @objc private func importExternalOpinionFile() {
        guard let target = currentTarget, sourceSeparationEnabled,
              interactionState.isIdle, sourceImportPanel == nil else { return }
        let panel = NSOpenPanel()
        sourceImportPanel = panel
        panel.title = "다른 세션의 의견이 담긴 텍스트 파일"
        panel.prompt = "가져오기"
        panel.allowedContentTypes = [.plainText, .text]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { [weak self, weak panel] response in
            guard let self, let panel, self.sourceImportPanel === panel else { return }
            self.sourceImportPanel = nil
            guard self.sourceSeparationEnabled, response == .OK, let url = panel.url else { return }
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: Inertbox.maximumInputBytes + 1) ?? Data()
                guard data.count <= Inertbox.maximumInputBytes,
                      let content = String(data: data, encoding: .utf8), !content.isEmpty else {
                    self.setStatus("64 KiB 이하의 UTF-8 텍스트 파일을 선택하세요")
                    return
                }
                self.beginExternalOpinionImport(content: content, target: target)
            } catch {
                self.setStatus("텍스트 파일을 읽지 못했습니다")
            }
        }
    }

    /// An explicit import captures a single selection, then carries its digest
    /// and range through the same write gate as an approved correction.
    private func beginExternalOpinionImport(content: String?, target requestedTarget: TargetApplication? = nil) {
        guard let target = requestedTarget ?? currentTarget, sourceSeparationEnabled else {
            setStatus("출처 구분을 켜고 입력할 앱을 선택하세요")
            return
        }
        guard AXIsProcessTrusted() else {
            requestAccessibilityPermission()
            return
        }
        if let content, content.isEmpty || content.utf8.count > Inertbox.maximumInputBytes || content.contains("\0") {
            setStatus("64 KiB 이하의 텍스트만 가져올 수 있습니다")
            return
        }
        guard let bridge = helperURL(named: "wds-ax-bridge") else { return }
        candidateTracker.cancelPendingInspection()
        interactionState.cancel(.candidateInspection)
        dismissCurrentDraftCandidate()
        guard let interaction = interactionState.begin(.sourceImport) else { return }
        setStatus("외부 의견을 넣을 선택 영역을 확인 중…")
        _ = target.application.activate(options: [.activateIgnoringOtherApps])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.interactionState.owns(interaction), self.editTargetIsReady(target, sourceImport: true) else {
                self?.interactionState.finish(interaction)
                return
            }
            let registry = self.sourceImportProcesses
            self.previewQueue.async { [weak self] in
                let process = Process()
                let outputPipe = Pipe()
                process.executableURL = bridge
                process.arguments = ["inspect-selection", "--bundle-id", target.bundleIdentifier]
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = outputPipe
                process.standardError = FileHandle.nullDevice
                var identifier: UUID?
                defer {
                    if process.isRunning { process.terminate() }
                    if let identifier { registry.finish(identifier) }
                }
                var resolved: (String, SafeDeleteInspection)?
                var status = "선택 영역을 읽지 못했습니다. 입력창에 커서를 두고 다시 시도하세요"
                do {
                    identifier = try registry.start(process)
                    let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       object["ok"] as? Bool == true, let selected = object["target"] as? String {
                        let original = content ?? selected
                        if original.isEmpty {
                            status = "다른 세션의 의견에 해당하는 구간을 먼저 선택하세요"
                        } else {
                            // Surrounding line breaks keep anchors at line starts
                            // even when the cursor was in the middle of a sentence.
                            let wrapped = "\n" + (try Inertbox.wrap(original)) + "\n"
                            switch SafeDeleteResponseValidator.parseInspection(
                                data, exactPhrase: selected,
                                expectedProcessIdentifier: target.processIdentifier,
                                replacement: wrapped, selectionOnly: true
                            ) {
                            case .success(let inspection): resolved = (selected, inspection)
                            case .failure(let failure): status = failure.status
                            }
                        }
                    }
                } catch {
                    status = "외부 의견을 가져오지 못했습니다. 입력 크기와 형식을 확인하세요"
                }
                let result = resolved
                let failureStatus = status
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.interactionState.owns(interaction) else { return }
                    guard let (selected, inspection) = result, self.editTargetIsReady(target, sourceImport: true) else {
                        self.interactionState.finish(interaction)
                        self.setStatus(failureStatus)
                        self.resumeCandidatePresentationIfPossible()
                        return
                    }
                    self.executeDelete(phrase: selected, inspection: inspection, target: target, interaction: interaction)
                }
            }
        }
    }

    @objc private func testEffect() {
        guard interactionState.isIdle,
              !candidatePresentation.isShowing
        else { return }
        let display = CGDisplayBounds(CGMainDisplayID())
        let size = CGSize(width: 240, height: 56)
        let rect = CGRect(
            x: display.midX - size.width / 2,
            y: display.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        playOverlay(
            rect: rect,
            motion: MotionSummary(direction: "north", speed: 1_800, distance: 240),
            displayText: "날려!",
            startingStatus: "화면 중앙에서 효과 테스트 중…",
            completionStatus: "효과 테스트 완료",
            failureStatus: "효과 테스트 실패"
        )
    }

    @objc private func previewFocusedInput() {
        guard inputCleanupEnabled,
              interactionState.isIdle,
              let target = currentTarget,
              allowedBundleIdentifiers.contains(target.bundleIdentifier)
        else { return }

        candidateTracker.cancelPendingInspection()
        dismissCurrentDraftCandidate()
        guard let interaction = interactionState.begin(.preview) else { return }
        let sheet = PreviewPhraseSheet()
        previewSheet = sheet
        sheet.present(for: target.name) { [weak self] phrase in
            guard let self else { return }
            self.previewSheet = nil
            guard self.interactionState.owns(interaction) else { return }
            guard let phrase else {
                self.interactionState.finish(interaction)
                if self.inputCleanupEnabled {
                    _ = target.application.activate(options: [.activateIgnoringOtherApps])
                    self.setStatus("Preview cancelled")
                }
                return
            }
            guard (phrase as NSString).length <= 4_096 else {
                self.interactionState.finish(interaction)
                self.setStatus("Preview phrase is too long")
                return
            }

            self.setStatus("Preparing preview…")
            _ = target.application.activate(options: [.activateIgnoringOtherApps])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, self.interactionState.owns(interaction) else { return }
                guard self.inputCleanupEnabled,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
                else {
                    self.interactionState.finish(interaction)
                    self.setStatus("Preview cancelled: target changed")
                    return
                }
                self.inspectForPreview(phrase: phrase, target: target, interaction: interaction)
            }
        }
    }

    @objc private func deleteExactPhrase() {
        beginDeleteExactPhrase(initialPhrase: "")
    }

    private func beginDeleteExactPhrase(initialPhrase: String) {
        guard inputCleanupEnabled,
              interactionState.isIdle,
              let target = currentTarget,
              allowedBundleIdentifiers.contains(target.bundleIdentifier)
        else { return }

        candidateTracker.cancelPendingInspection()
        dismissCurrentDraftCandidate()
        guard let interaction = interactionState.begin(.delete) else { return }
        let sheet = DeletePhraseSheet()
        deleteSheet = sheet
        sheet.present(for: target.name, initialPhrase: initialPhrase) { [weak self] phrase in
            guard let self else { return }
            self.deleteSheet = nil
            guard self.interactionState.owns(interaction) else { return }
            guard let phrase else {
                self.interactionState.finish(interaction)
                if self.inputCleanupEnabled {
                    _ = target.application.activate(options: [.activateIgnoringOtherApps])
                    self.setStatus("Delete cancelled")
                }
                return
            }
            guard (phrase as NSString).length <= 4_096 else {
                self.interactionState.finish(interaction)
                self.setStatus("Delete phrase is too long")
                return
            }

            self.clearCurrentLocalDraft()
            self.setStatus("Inspecting exact phrase…")
            _ = target.application.activate(options: [.activateIgnoringOtherApps])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, self.interactionState.owns(interaction) else { return }
                guard self.editTargetIsReady(target) else {
                    self.interactionState.finish(interaction)
                    self.setStatus("Delete cancelled: target or focus changed")
                    return
                }
                self.inspectForDelete(
                    phrase: phrase,
                    target: target,
                    interaction: interaction
                )
            }
        }
    }

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }

    @objc private func requestAccessibilityPermission() {
        let accessibilityOptions = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true,
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(accessibilityOptions)
        let pollIdentifier = UUID()
        accessibilityPermissionPollIdentifier = pollIdentifier
        pollAccessibilityPermission(
            identifier: pollIdentifier,
            remainingAttempts: 120
        )
        setStatus("Accessibility permission request opened")
    }

    private func pollAccessibilityPermission(
        identifier: UUID,
        remainingAttempts: Int
    ) {
        guard accessibilityPermissionPollIdentifier == identifier else { return }
        if AXIsProcessTrusted() {
            accessibilityPermissionPollIdentifier = nil
            frontmostApplicationChanged(NSWorkspace.shared.frontmostApplication)
            return
        }
        guard remainingAttempts > 0 else {
            accessibilityPermissionPollIdentifier = nil
            setStatus("손쉬운 사용 권한 필요 — WDS를 허용하세요")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.pollAccessibilityPermission(
                identifier: identifier,
                remainingAttempts: remainingAttempts - 1
            )
        }
    }

    @objc private func requestMouseEffectPermission() {
        _ = CGRequestListenEventAccess()
        setStatus("Optional mouse-effect permission request opened")
    }

    @objc private func toggleMotionCapture() {
        guard inputCleanupEnabled, !localSessionDetectionEnabled else { return }
        motionCaptureEnabled.toggle()
        stopSensor(wait: false)
        reconcileSensor()
        setStatus(motionCaptureEnabled
            ? "Recent mouse motion enabled for this launch"
            : "Recent mouse motion disabled")
    }

    private func persistAllowlist() {
        defaults.set(allowedBundleIdentifiers.sorted(), forKey: Preferences.allowedBundleIdentifiers)
        defaults.set(
            autoWatchBundleIdentifiers.sorted(),
            forKey: Preferences.autoWatchBundleIdentifiers
        )
    }

    private func frontmostApplicationChanged(_ application: NSRunningApplication?) {
        terminalReview.cancelIfTargetChanged(application?.processIdentifier)
        if application?.bundleIdentifier == ownBundleIdentifier {
            clearCurrentLocalDraft()
            latestMotion = .stationary
            return
        }
        if let application,
           application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
           let target = TargetApplication(application),
           target.bundleIdentifier != ownBundleIdentifier {
            currentTarget = target
        } else {
            currentTarget = nil
        }
        if localSessionDetectionEnabled, let scope = localSessionScope {
            let scopeStillMatches = currentTarget.map(scope.matches) == true
            if !scopeStillMatches {
                localSessionDetectionEnabled = false
                localSessionScope = nil
                resetLocalSessionData()
                stopSensor(wait: false)
            }
        }
        activateAutomaticDraftWatchIfNeeded()
        reconcileSensor()
    }

    private func activateAutomaticDraftWatchIfNeeded() {
        guard inputCleanupEnabled,
              AXIsProcessTrusted(),
              sessionDetectionConsentSheet == nil,
              let target = currentTarget,
              allowedBundleIdentifiers.contains(target.bundleIdentifier),
              (autoWatchBundleIdentifiers.contains(target.bundleIdentifier)
                  || sessionWatchBundleIdentifiers.contains(target.bundleIdentifier)),
              localSessionScope?.matches(target) != true
        else { return }

        disableLocalSessionDetection(restartSensor: false)
        localSessionDetectionEnabled = true
        localSessionScope = LocalSessionScope(
            bundleIdentifier: target.bundleIdentifier,
            processIdentifier: target.processIdentifier
        )
    }

    private func reconcileSensor() {
        guard inputCleanupEnabled else {
            stopSensor(wait: false)
            setStatus(sourceSeparationEnabled ? "출처 구분만 켜짐 • 초안 감시 안 함" : "입력 정리와 출처 구분 꺼짐")
            return
        }
        guard AXIsProcessTrusted() else {
            stopSensor(wait: false)
            setStatus("손쉬운 사용 권한 필요 — WDS를 허용하세요")
            return
        }
        guard let target = currentTarget else {
            stopSensor(wait: false)
            setStatus("입력할 앱을 먼저 선택하세요")
            return
        }
        guard allowedBundleIdentifiers.contains(target.bundleIdentifier) else {
            stopSensor(wait: false)
            setStatus("현재 앱에서 ‘입력 정리 시작’을 누르세요")
            return
        }
        if let sensorSession,
           sensorSession.target.processIdentifier == target.processIdentifier,
           sensorSession.target.bundleIdentifier == target.bundleIdentifier,
           sensorSession.rawTextEnabled == shouldCaptureRawText(for: target),
           sensorSession.textOnly == shouldUseTextOnlySensor(for: target),
           sensorSession.process.isRunning {
            return
        }
        stopSensor(wait: false)
        startSensor(for: target)
    }

    private func startSensor(for target: TargetApplication) {
        guard let executableURL = helperURL(named: "wds-sensor") else {
            setStatus("Sensor helper is missing")
            return
        }

        let process = Process()
        let outputPipe = Pipe()
        let rawTextEnabled = shouldCaptureRawText(for: target)
        let textOnly = shouldUseTextOnlySensor(for: target)
        process.executableURL = executableURL
        var arguments = ["--bundle-id", target.bundleIdentifier, "--mouse-window-ms", "2000"]
        if rawTextEnabled { arguments.append("--emit-text") }
        if textOnly { arguments.append("--text-only") }
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        let session = SensorSession(
            target: target,
            process: process,
            outputPipe: outputPipe,
            rawTextEnabled: rawTextEnabled,
            textOnly: textOnly
        )
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self, weak session] handle in
            guard let self, let session else { return }
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let batch = session.parser.append(data)
            DispatchQueue.main.async { [weak self] in
                self?.handleSensorBatch(batch, sessionIdentifier: session.identifier)
            }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.sensorTerminated(sessionIdentifier: session.identifier)
            }
        }

        do {
            try process.run()
            sensorSession = session
            latestMotion = .stationary
            if rawTextEnabled {
                setStatus("현재 초안 감시 시작 중 • 토큰 0")
            } else if textOnly {
                setStatus("Starting redacted text-only sensor…")
            } else {
                setStatus("Starting redacted text + mouse sensor…")
            }
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            setStatus("Could not start sensor")
        }
    }

    private func stopSensor(wait: Bool) {
        guard let session = sensorSession else {
            latestMotion = .stationary
            clearCurrentLocalDraft()
            return
        }
        sensorSession = nil
        latestMotion = .stationary
        clearCurrentLocalDraft()
        session.outputPipe.fileHandleForReading.readabilityHandler = nil
        session.process.terminationHandler = nil
        session.parser.clear()
        try? session.outputPipe.fileHandleForReading.close()
        guard session.process.isRunning else { return }
        session.process.terminate()

        if wait {
            let deadline = Date().addingTimeInterval(0.25)
            while Date() < deadline, session.process.isRunning {
                usleep(10_000)
            }
            if session.process.isRunning {
                kill(session.process.processIdentifier, SIGKILL)
            }
        } else {
            let process = session.process
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.75) {
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }
    }

    private func handleSensorBatch(_ batch: JSONLineBatch, sessionIdentifier: UUID) {
        guard let session = sensorSession, session.identifier == sessionIdentifier else { return }
        if batch.overflowed {
            rejectSensorSession(session, status: "Sensor output was rejected")
            return
        }
        for event in batch.objects {
            handleSensorEvent(event, sessionIdentifier: sessionIdentifier)
            guard sensorSession?.identifier == sessionIdentifier else { return }
        }
    }

    private func handleSensorEvent(_ event: [String: Any], sessionIdentifier: UUID) {
        guard let session = sensorSession, session.identifier == sessionIdentifier else { return }
        guard let eventType = event["type"] as? String,
              let bundleIdentifier = event["bundle_id"] as? String,
              bundleIdentifier == session.target.bundleIdentifier else {
            rejectSensorSession(session, status: "Sensor target mismatch")
            return
        }

        if eventType != "text_snapshot", event["text"] != nil {
            rejectSensorSession(session, status: "Sensor privacy check failed")
            return
        }
        if eventType != "sensor_started" {
            guard sensorEventProcessIdentifier(event) == session.target.processIdentifier,
                  eventType == "error" || session.configurationAttested else {
                rejectSensorSession(session, status: "Sensor event attestation failed")
                return
            }
        }

        switch eventType {
        case "sensor_started":
            guard !session.configurationAttested,
                  event["raw_text_enabled"] as? Bool == session.rawTextEnabled,
                  event["text_only"] as? Bool == session.textOnly,
                  event["input_monitoring_required"] as? Bool == !session.textOnly,
                  event["mouse_output"] as? String == (session.textOnly
                    ? "disabled"
                    : "derived_summary_only"),
                  sensorEventProcessIdentifier(event) == session.target.processIdentifier else {
                rejectSensorSession(session, status: "Sensor mode attestation failed")
                return
            }
            session.configurationAttested = true
            if session.rawTextEnabled {
                setStatus("현재 초안 감시 중 • 로컬 • 토큰 0")
            } else if session.textOnly {
                setStatus("Monitoring redacted text • mouse off")
            } else {
                setStatus("Monitoring redacted text + mouse motion")
            }
        case "text_snapshot":
            guard session.configurationAttested,
                  sensorEventProcessIdentifier(event) == session.target.processIdentifier,
                  let focusEpoch = sensorEventInteger(event["focus_epoch"]),
                  focusEpoch >= 0 else {
                rejectSensorSession(session, status: "Sensor privacy check failed")
                return
            }
            if session.focusEpoch != focusEpoch {
                clearCurrentLocalDraft()
                session.focusEpoch = focusEpoch
            }

            if session.rawTextEnabled {
                guard event["text_redacted"] as? Bool == false,
                      let text = event["text"] as? String,
                      let reportedLength = sensorEventInteger(event["utf16_length"]),
                      reportedLength == (text as NSString).length,
                      text.utf8.count <= 64 * 1_024 else {
                    rejectSensorSession(session, status: "Local draft snapshot was rejected")
                    return
                }
                currentLocalDraft = text.isEmpty ? nil : CurrentDraftSnapshot(
                    bundleIdentifier: session.target.bundleIdentifier,
                    processIdentifier: session.target.processIdentifier,
                    focusEpoch: focusEpoch,
                    text: text
                )
                if text.isEmpty {
                    clearCurrentLocalDraft()
                    session.focusEpoch = focusEpoch
                    setStatus("현재 초안 감시 중 • 입력창이 비어 있음")
                } else {
                    refreshCurrentDraftCandidate()
                }
            } else {
                guard event["text_redacted"] as? Bool == true,
                      event["text"] == nil else {
                    rejectSensorSession(session, status: "Sensor privacy check failed")
                    return
                }
                setStatus("Focused editable input detected")
            }
            if let mouse = event["recent_mouse"] as? [String: Any] {
                latestMotion = motionSummary(from: mouse)
            }
        case "mouse_summary":
            if let summary = event["summary"] as? [String: Any] {
                latestMotion = motionSummary(from: summary)
                if !session.rawTextEnabled {
                    setStatus("Monitoring • mouse \(latestMotion.direction)")
                }
            }
        case "secure_field_ignored":
            guard let focusEpoch = sensorEventInteger(event["focus_epoch"]), focusEpoch >= 0 else {
                rejectSensorSession(session, status: "Sensor focus boundary was rejected")
                return
            }
            resetLocalSessionData()
            session.focusEpoch = focusEpoch
            latestMotion = .stationary
            setStatus("Secure field ignored")
        case "focused_element_ignored":
            guard let focusEpoch = sensorEventInteger(event["focus_epoch"]), focusEpoch >= 0 else {
                rejectSensorSession(session, status: "Sensor focus boundary was rejected")
                return
            }
            clearCurrentLocalDraft()
            session.focusEpoch = focusEpoch
            latestMotion = .stationary
            setStatus("Waiting for editable input")
        case "text_snapshot_error":
            guard let focusEpoch = sensorEventInteger(event["focus_epoch"]), focusEpoch >= 0 else {
                rejectSensorSession(session, status: "Sensor focus boundary was rejected")
                return
            }
            resetLocalSessionData()
            session.focusEpoch = focusEpoch
            setStatus("Focused input is unavailable")
        case "app_focus":
            guard let active = event["active"] as? Bool else {
                rejectSensorSession(session, status: "Sensor focus state was rejected")
                return
            }
            if !active {
                clearCurrentLocalDraft()
                session.focusEpoch = nil
                latestMotion = .stationary
                setStatus("Target app inactive; local draft released")
            }
        case "error":
            let error = event["error"] as? [String: Any]
            let code = error?["code"] as? String
            rejectSensorSession(session, status: sensorErrorStatus(code: code))
        case "target_app_terminated":
            rejectSensorSession(session, status: "Target app terminated")
        case "sensor_stopped":
            rejectSensorSession(session, status: "Sensor stopped")
        default:
            rejectSensorSession(session, status: "Unknown sensor event was rejected")
        }
    }

    private func rejectSensorSession(_ session: SensorSession, status: String) {
        if session.rawTextEnabled {
            localSessionDetectionEnabled = false
            localSessionScope = nil
            resetLocalSessionData()
        } else {
            clearCurrentLocalDraft()
        }
        stopSensor(wait: false)
        setStatus(status)
    }

    private func sensorEventProcessIdentifier(_ event: [String: Any]) -> pid_t? {
        guard let value = sensorEventInteger(event["pid"]),
              value > 0, value <= Int(Int32.max) else { return nil }
        return pid_t(value)
    }

    private func sensorEventInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite,
              double.rounded(.towardZero) == double,
              double >= Double(Int.min), double <= Double(Int.max) else { return nil }
        return Int(double)
    }

    private func sensorTerminated(sessionIdentifier: UUID) {
        guard let session = sensorSession, session.identifier == sessionIdentifier else { return }
        sensorSession = nil
        latestMotion = .stationary
        if session.rawTextEnabled {
            localSessionDetectionEnabled = false
            localSessionScope = nil
            resetLocalSessionData()
        } else {
            clearCurrentLocalDraft()
        }
        setStatus("Sensor stopped")
    }

    private func inspectForPreview(
        phrase: String,
        target: TargetApplication,
        interaction: InteractionToken
    ) {
        guard let executableURL = helperURL(named: "wds-ax-bridge") else {
            interactionState.finish(interaction)
            setStatus("Preview bridge is missing")
            return
        }

        let registry = ephemeralProcesses
        previewQueue.async { [weak self] in
            let process = Process()
            let inputPipe = Pipe()
            let outputPipe = Pipe()
            process.executableURL = executableURL
            process.arguments = ["inspect", "--target-stdin", "--bundle-id", target.bundleIdentifier]
            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            process.standardError = FileHandle.nullDevice
            defer { try? inputPipe.fileHandleForWriting.close() }
            var launchedIdentifier: UUID?
            defer {
                if process.isRunning { process.terminate() }
                if let launchedIdentifier { registry.finish(launchedIdentifier) }
            }

            let result: PreviewInspectionResult
            do {
                let processIdentifier = try registry.start(process)
                launchedIdentifier = processIdentifier
                try inputPipe.fileHandleForWriting.write(contentsOf: Data(phrase.utf8))
                try inputPipe.fileHandleForWriting.close()
                let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                result = Self.previewRect(from: output)
            } catch {
                result = .failure("Preview inspection was cancelled")
            }

            DispatchQueue.main.async { [weak self] in
                self?.finishPreviewInspection(
                    result,
                    phrase: phrase,
                    target: target,
                    interaction: interaction
                )
            }
        }
    }

    private func inspectForDelete(
        phrase: String,
        replacement: String = "",
        target: TargetApplication,
        interaction: InteractionToken
    ) {
        guard let executableURL = helperURL(named: "wds-ax-bridge") else {
            interactionState.finish(interaction)
            setStatus("Delete bridge is missing")
            resumeCandidatePresentationIfPossible()
            return
        }

        let registry = ephemeralProcesses
        previewQueue.async { [weak self] in
            let process = Process()
            let inputPipe = Pipe()
            let outputPipe = Pipe()
            process.executableURL = executableURL
            process.arguments = ["inspect", "--target-stdin", "--bundle-id", target.bundleIdentifier]
            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            process.standardError = FileHandle.nullDevice
            var launchedIdentifier: UUID?
            defer {
                try? inputPipe.fileHandleForWriting.close()
                if process.isRunning { process.terminate() }
                if let launchedIdentifier { registry.finish(launchedIdentifier) }
            }

            let result: DeleteInspectionResult
            do {
                launchedIdentifier = try registry.start(process)
                try inputPipe.fileHandleForWriting.write(contentsOf: Data(phrase.utf8))
                try inputPipe.fileHandleForWriting.close()
                let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                switch SafeDeleteResponseValidator.parseInspection(
                    output,
                    exactPhrase: phrase,
                    expectedProcessIdentifier: target.processIdentifier,
                    replacement: replacement
                ) {
                case .success(let inspection):
                    result = .success(inspection)
                case .failure(let failure):
                    result = .failure(failure.status)
                }
            } catch {
                result = .failure("Delete inspection was cancelled")
            }

            DispatchQueue.main.async { [weak self] in
                self?.finishDeleteInspection(
                    result,
                    phrase: phrase,
                    target: target,
                    interaction: interaction
                )
            }
        }
    }

    private func finishDeleteInspection(
        _ result: DeleteInspectionResult,
        phrase: String,
        target: TargetApplication,
        interaction: InteractionToken
    ) {
        guard interactionState.owns(interaction) else { return }
        guard inputCleanupEnabled, allowedBundleIdentifiers.contains(target.bundleIdentifier) else {
            interactionState.finish(interaction)
            setStatus("Delete cancelled")
            resumeCandidatePresentationIfPossible()
            return
        }

        switch result {
        case .failure(let status):
            interactionState.finish(interaction)
            setStatus(status)
            resumeCandidatePresentationIfPossible()
        case .success(let inspection):
            setStatus("Rechecking target before deletion…")
            _ = target.application.activate(options: [.activateIgnoringOtherApps])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, self.interactionState.owns(interaction) else { return }
                guard self.editTargetIsReady(target),
                      inspection.processIdentifier == target.processIdentifier
                else {
                    self.interactionState.finish(interaction)
                    self.setStatus("Delete cancelled: target or focus changed")
                    self.resumeCandidatePresentationIfPossible()
                    return
                }
                self.executeDelete(
                    phrase: phrase,
                    inspection: inspection,
                    target: target,
                    interaction: interaction
                )
            }
        }
    }

    private func executeDelete(
        phrase: String,
        inspection: SafeDeleteInspection,
        target: TargetApplication,
        interaction: InteractionToken
    ) {
        guard interactionState.owns(interaction),
              editTargetIsReady(target, sourceImport: inspection.selectionOnly) else {
            interactionState.finish(interaction)
            resumeCandidatePresentationIfPossible()
            return
        }
        guard let executableURL = helperURL(named: "wds-ax-bridge") else {
            interactionState.finish(interaction)
            setStatus("Delete bridge is missing")
            resumeCandidatePresentationIfPossible()
            return
        }

        setStatus("승인한 구간을 적용 중…")
        let registry = inspection.selectionOnly ? sourceImportProcesses : ephemeralProcesses
        previewQueue.async { [weak self] in
            let process = Process()
            let inputPipe = Pipe()
            let outputPipe = Pipe()
            process.executableURL = executableURL
            process.arguments = inspection.bridgeArguments(bundleIdentifier: target.bundleIdentifier)
            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            process.standardError = FileHandle.nullDevice
            var launchedIdentifier: UUID?
            defer {
                try? inputPipe.fileHandleForWriting.close()
                if process.isRunning { process.terminate() }
                if let launchedIdentifier { registry.finish(launchedIdentifier) }
            }

            let result: DeleteExecutionResult
            do {
                launchedIdentifier = try registry.start(process)
                try inputPipe.fileHandleForWriting.write(contentsOf: try inspection.bridgeInput(target: phrase))
                try inputPipe.fileHandleForWriting.close()
                let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                switch SafeDeleteResponseValidator.validateDeletion(output, against: inspection) {
                case .success:
                    result = .success
                case .failure(let failure):
                    result = .failure(failure.status)
                }
            } catch {
                result = .failure("Safe deletion was cancelled")
            }

            DispatchQueue.main.async { [weak self] in
                self?.finishDelete(
                    result,
                    phrase: phrase,
                    inspection: inspection,
                    target: target,
                    interaction: interaction
                )
            }
        }
    }

    private func finishDelete(
        _ result: DeleteExecutionResult,
        phrase: String,
        inspection: SafeDeleteInspection,
        target: TargetApplication,
        interaction: InteractionToken
    ) {
        guard interactionState.finish(interaction) else { return }
        guard inspection.selectionOnly
            ? sourceSeparationEnabled
            : (inputCleanupEnabled && allowedBundleIdentifiers.contains(target.bundleIdentifier)) else { return }

        switch result {
        case .success:
            if inspection.isReplacement {
                setStatus(inspection.selectionOnly ? "외부 의견과 검토 지침을 입력했습니다" : "승인한 문구를 고쳤습니다")
                resumeCandidatePresentationIfPossible()
                return
            }
            let rectangle = inspection.overlayRectangle
            playOverlay(
                rect: CGRect(
                    x: rectangle.x,
                    y: rectangle.y,
                    width: rectangle.width,
                    height: rectangle.height
                ),
                motion: latestMotion,
                displayText: phrase,
                geometryIsEstimated: inspection.overlayIsEstimated,
                startingStatus: "Exact phrase deleted; playing effect",
                completionStatus: "Exact phrase deleted",
                failureStatus: "문구는 삭제됐지만 효과 확인 실패"
            )
        case .failure(let status):
            setStatus(status)
            resumeCandidatePresentationIfPossible()
        }
    }

    private func editTargetIsReady(_ target: TargetApplication, sourceImport: Bool = false) -> Bool {
        // Explicit source imports authorize one edit; they never opt the app
        // into continuous input cleanup or require its watch allowlist.
        let featureAllowsEdit = sourceImport
            ? sourceSeparationEnabled
            : (inputCleanupEnabled && allowedBundleIdentifiers.contains(target.bundleIdentifier))
        return featureAllowsEdit
            && AXIsProcessTrusted()
            && !target.application.isTerminated
            && target.application.isActive
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
    }

    private func finishPreviewInspection(
        _ result: PreviewInspectionResult,
        phrase: String,
        target: TargetApplication,
        interaction: InteractionToken
    ) {
        guard interactionState.finish(interaction) else { return }
        guard inputCleanupEnabled,
              allowedBundleIdentifiers.contains(target.bundleIdentifier),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
        else {
            setStatus("Preview cancelled: target changed")
            return
        }

        switch result {
        case .success(let overlayTarget):
            playOverlay(
                rect: overlayTarget.rectangle,
                motion: latestMotion,
                displayText: phrase,
                geometryIsEstimated: overlayTarget.isEstimated
            )
        case .failure(let status):
            setStatus(status)
        }
    }

    private func playOverlay(
        rect: CGRect,
        motion: MotionSummary,
        displayText: String,
        geometryIsEstimated: Bool = false,
        startingStatus: String = "Playing visual-only preview",
        completionStatus: String = "Preview complete",
        failureStatus: String = "효과 확인 실패"
    ) {
        guard interactionState.isIdle else {
            setStatus("이미 다른 작업을 처리 중입니다")
            return
        }
        guard let executableURL = helperURL(named: "wds-whack") else {
            lastOverlayOutcome = .failed("도우미 없음")
            setStatus("\(failureStatus) • 도우미 없음")
            return
        }
        let inputData = Data(displayText.utf8)
        guard case .success = GlyphTextInput.parse(inputData) else {
            lastOverlayOutcome = .failed("글자 입력 범위 초과")
            setStatus("\(failureStatus) • 글자 입력 범위 초과")
            return
        }
        guard let interaction = interactionState.begin(.overlay) else { return }
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executableURL
        var arguments = [
            "--x", String(Double(rect.origin.x)),
            "--y", String(Double(rect.origin.y)),
            "--width", String(Double(rect.size.width)),
            "--height", String(Double(rect.size.height)),
            "--duration-ms", String(overlayDurationMilliseconds),
            "--motion-direction", motion.direction,
            "--motion-speed", String(motion.speed),
            "--motion-distance", String(motion.distance),
            "--text-stdin",
            "--report-json",
        ]
        if geometryIsEstimated {
            arguments.append("--geometry-estimated")
        }
        process.arguments = arguments
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: inputData)
            try inputPipe.fileHandleForWriting.close()
            _ = try overlayProcesses.start(
                process,
                terminationHandler: { [weak self] _, finishedProcess in
                    let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    _ = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let terminationStatus = finishedProcess.terminationStatus
                    let report = OverlayRenderReportCodec.parse(
                        output,
                        expectedDurationMilliseconds: self?.overlayDurationMilliseconds ?? 0
                    )
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.interactionState.finish(interaction) else { return }
                        defer { self.resumeCandidatePresentationIfPossible() }
                        guard terminationStatus == 0 else {
                            let reason = "도우미 종료 \(terminationStatus)"
                            self.lastOverlayOutcome = .failed(reason)
                            self.setStatus("\(failureStatus) • \(reason)")
                            return
                        }
                        switch report {
                        case .success(let verified):
                            self.lastOverlayOutcome = .verified(
                                frames: verified.framesDrawn,
                                elapsedMilliseconds: verified.elapsedMilliseconds
                            )
                            let renderDescription = verified.fallbackUsed
                                ? "추정 위치 글자 효과"
                                : "글자 \(verified.glyphFramesDrawn)프레임"
                            self.setStatus("\(completionStatus) • \(renderDescription) 렌더 확인")
                        case .failure(let error):
                            let reason = Self.overlayFailureReason(error)
                            self.lastOverlayOutcome = .failed(reason)
                            self.setStatus("\(failureStatus) • \(reason)")
                        }
                    }
                }
            )
            lastOverlayOutcome = .rendering
            scheduleOverlayWatchdog(for: process)
            setStatus(startingStatus)
        } catch {
            interactionState.finish(interaction)
            lastOverlayOutcome = .failed("시작하지 못함")
            setStatus("\(failureStatus) • 시작하지 못함")
        }
    }

    private func scheduleOverlayWatchdog(for process: Process) {
        let timeout = Double(overlayDurationMilliseconds) / 1_000 + 2
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak process] in
            guard let process, process.isRunning else { return }
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { [weak process] in
                guard let process, process.isRunning else { return }
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    private func resumeCandidatePresentationIfPossible() {
        guard let ticket = candidateTracker.resumeInspection(
            isPanelVisible: candidatePresentation.isShowing,
            engineEnabled: inputCleanupEnabled,
            isIdle: interactionState.isIdle
        ) else { return }
        armCandidateInspection(
            ticket,
            delay: CurrentDraftCandidateTracker.resumeDebounce
        )
    }

    private static func overlayFailureReason(_ failure: OverlayRenderReportFailure) -> String {
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

    private static func previewRect(from data: Data) -> PreviewInspectionResult {
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

    private static func rectangle(from value: Any?) -> CGRect? {
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

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    private static func integer(_ value: Any?) -> Int? {
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

    private static func bridgeErrorStatus(code: String?) -> String {
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

    private func motionSummary(from dictionary: [String: Any]) -> MotionSummary {
        MotionSummary(
            direction: dictionary["direction"] as? String ?? "stationary",
            speed: (dictionary["average_speed_points_per_second"] as? NSNumber)?.doubleValue ?? 0,
            distance: (dictionary["distance_points"] as? NSNumber)?.doubleValue ?? 0
        )
    }

    private func sensorErrorStatus(code: String?) -> String {
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

    private func helperURL(named name: String) -> URL? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    private func displayName(for bundleIdentifier: String) -> String {
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

    private func setStatus(_ status: String) {
        statusText = status
        let marker: String
        if candidatePresentation.isShowing {
            marker = "!"
        } else if localSessionDetectionEnabled {
            marker = "●"
        } else if features.anyEnabled {
            marker = "◐"
        } else {
            marker = "○"
        }
        statusItem?.button?.title = "WDS \(marker)"
        statusItem?.button?.toolTip = "입력 정리 \(inputCleanupEnabled ? "켬" : "끔") · 출처 구분 \(sourceSeparationEnabled ? "켬" : "끔") — \(status)"
        statusMenuItem?.title = "상태: \(status)"
    }
}

private let application = NSApplication.shared
// Hold one OS lock across paths and launch races, before any helper or socket
// starts. Reopening an app must not resolve another build through Launch Services.
private let instanceLock = SingleInstanceLock()
guard instanceLock.acquire() else {
    exit(0)
}
application.setActivationPolicy(.accessory)
private let delegate = AppDelegate()
application.delegate = delegate
withExtendedLifetime(delegate) {
    application.run()
}
