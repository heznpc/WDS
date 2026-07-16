import ApplicationServices
import AppKit
import CoreGraphics
import Darwin
import Foundation
import WDSAppCore
import WDSWhackCore

private enum Preferences {
    static let enabled = "wds.enabled"
    static let allowedBundleIdentifiers = "wds.allowedBundleIdentifiers"
    static let autoWatchBundleIdentifiers = "wds.autoWatchBundleIdentifiers.v1"
    static let tokenSavingsLedger = "wds.tokenSavingsLedger.v1"
    static let tokenSavingsLedgerCorruptBackup = "wds.tokenSavingsLedger.v1.corruptBackup"
    static let phraseDictionary = "wds.phraseDictionary.v1"
    static let phraseDictionaryCorruptBackup = "wds.phraseDictionary.v1.corruptBackup"
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

private struct LocalDraftSnapshot {
    let bundleIdentifier: String
    let processIdentifier: pid_t
    let focusEpoch: Int
    let text: String
}

private struct CurrentDraftCandidateIdentity: Equatable {
    let bundleIdentifier: String
    let processIdentifier: pid_t
    let focusEpoch: Int
    let range: CurrentDraftUTF16Range
    let originalText: String
}

private struct CurrentDraftCandidateState {
    let identity: CurrentDraftCandidateIdentity
    let candidate: CurrentDraftDeletionCandidate

    var displayPhrase: String {
        candidate.originalText.trimmingCharacters(in: .whitespacesAndNewlines)
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
    private let ephemeralProcesses = EphemeralProcessRegistry()
    private let overlayProcesses = EphemeralProcessRegistry()
    private let terminalSocketServer = TerminalSocketServer()
    private let previewQueue = DispatchQueue(label: "com.heznpc.WDS.preview", qos: .userInitiated)
    private let ownBundleIdentifier = "com.heznpc.WDS"
    private let currentDraftAnalyzer = CurrentDraftAnalyzer(maximumCandidates: 1)
    private let dictionaryMatcher = DictionaryMatcher()
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
    private var phraseDictionary = PhraseDictionary()
    private var sessionWatchBundleIdentifiers = Set<String>()
    private var enabled = false
    private var currentTarget: TargetApplication?
    private var sensorSession: SensorSession?
    private var statusText = "Disabled"
    private var latestMotion = MotionSummary.stationary
    private var previewSheet: PreviewPhraseSheet?
    private var deleteSheet: DeletePhraseSheet?
    private var terminalServerReady = false
    private var motionCaptureEnabled = false
    private var localSessionDetectionEnabled = false
    private var localSessionScope: LocalSessionScope?
    private var currentLocalDraft: LocalDraftSnapshot?
    private var sessionDetectionConsentSheet: SessionDetectionConsentSheet?
    private var currentDraftCandidateState: CurrentDraftCandidateState?
    private var suppressedCandidateIdentity: CurrentDraftCandidateIdentity?
    private var typingDismissedCandidateIdentity: CurrentDraftCandidateIdentity?
    private var candidateDebounceIdentifier: UUID?
    private var interactionState = InteractionState()
    private var accessibilityPermissionPollIdentifier: UUID?
    private var lastOverlayOutcome = OverlayOutcome.notTested
    private var savingsLedger = SavingsLedger()

    func applicationDidFinishLaunching(_ notification: Notification) {
        enabled = defaults.bool(forKey: Preferences.enabled)
        allowedBundleIdentifiers = Set(defaults.stringArray(forKey: Preferences.allowedBundleIdentifiers) ?? [])
        autoWatchBundleIdentifiers = Set(
            defaults.stringArray(forKey: Preferences.autoWatchBundleIdentifiers) ?? []
        )
        savingsLedger = loadSavingsLedger()
        phraseDictionary = loadPhraseDictionary()
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

    private func rebuildMenu() {
        menu.removeAllItems()

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
        if currentAutoWatch, let currentTarget {
            primaryTitle = "\(currentTarget.name) 자동 감시 해제"
        } else if !AXIsProcessTrusted() {
            primaryTitle = "WDS 텍스트 접근 권한 부여…"
        } else if let currentTarget {
            primaryTitle = scopeMatchesCurrent
                ? "\(currentTarget.name)에서 WDS 중지"
                : "\(currentTarget.name)에서 WDS 시작…"
        } else {
            primaryTitle = "입력할 앱을 먼저 선택하세요"
        }
        let primaryAction = NSMenuItem(
            title: primaryTitle,
            action: #selector(toggleWDSForCurrentApplication),
            keyEquivalent: ""
        )
        primaryAction.target = self
        primaryAction.state = (scopeMatchesCurrent || currentAutoWatch) ? .on : .off
        primaryAction.isEnabled = currentTarget != nil
            && !interactionState.isActive(.preview)
            && !interactionState.isActive(.delete)
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
            title: "사용: 문장 입력 → 잠시 멈춤 → 후보에서 ‘날리기’",
            action: nil,
            keyEquivalent: ""
        )
        usageNote.isEnabled = false
        menu.addItem(usageNote)

        let weeklyTokens = savingsLedger.tokens(inPeriod: SavingsPeriod.weekKey(for: Date()))
        let savingsTitle: String
        if savingsLedger.lifetimeTokens == 0 {
            savingsTitle = "이번 주 정리한 토큰: 아직 없음 (추정)"
        } else {
            savingsTitle = "이번 주 약 \(weeklyTokens)토큰 정리 · 누적 \(savingsLedger.lifetimeTokens)토큰 (추정)"
        }
        let savingsNote = NSMenuItem(title: savingsTitle, action: nil, keyEquivalent: "")
        savingsNote.isEnabled = false
        savingsNote.toolTip = "로컬 추정치입니다. 실제 청구 토큰과 다를 수 있으며 대화가 길어질수록 절약 효과는 커집니다."
        menu.addItem(savingsNote)

        let effectTest = NSMenuItem(
            title: interactionState.isActive(.overlay) ? "효과 렌더 중…" : "효과 테스트",
            action: #selector(testEffect),
            keyEquivalent: ""
        )
        effectTest.target = self
        effectTest.isEnabled = interactionState.isIdle
            && !currentDraftCandidatePanel.isVisible
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

        let enabledItem = NSMenuItem(title: "Engine Enabled (Advanced)", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledItem.target = self
        enabledItem.state = enabled ? .on : .off
        menu.addItem(enabledItem)
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

        let dictionaryItem = NSMenuItem(title: "말버릇 사전", action: nil, keyEquivalent: "")
        let dictionaryMenu = NSMenu()
        let addPhrase = NSMenuItem(
            title: "말버릇 추가…",
            action: #selector(addPhraseEntry),
            keyEquivalent: ""
        )
        addPhrase.target = self
        addPhrase.toolTip = "전송 전에 초안에서 찾을 문구를 등록합니다 (삭제 또는 치환)"
        dictionaryMenu.addItem(addPhrase)
        dictionaryMenu.addItem(.separator())
        if phraseDictionary.entries.isEmpty {
            let empty = NSMenuItem(title: "등록된 문구 없음", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            dictionaryMenu.addItem(empty)
        } else {
            for entry in phraseDictionary.entries {
                var title = entry.phrase + (entry.requireComma ? "," : "")
                if entry.isReplacement { title += " → \(entry.replacement)" }
                if !entry.isActive { title += "  (중지)" }
                let entryItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                let entryMenu = NSMenu()
                let toggle = NSMenuItem(
                    title: entry.isActive ? "사용 중 (끄기)" : "중지됨 (켜기)",
                    action: #selector(togglePhraseEntry(_:)),
                    keyEquivalent: ""
                )
                toggle.target = self
                toggle.state = entry.isActive ? .on : .off
                toggle.representedObject = entry.id
                entryMenu.addItem(toggle)
                let remove = NSMenuItem(
                    title: "제거",
                    action: #selector(removePhraseEntry(_:)),
                    keyEquivalent: ""
                )
                remove.target = self
                remove.representedObject = entry.id
                entryMenu.addItem(remove)
                entryItem.submenu = entryMenu
                dictionaryMenu.addItem(entryItem)
            }
        }
        dictionaryItem.submenu = dictionaryMenu
        menu.addItem(dictionaryItem)

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
        detectionToggle.isEnabled = enabled && currentAllowed
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

        if let candidate = currentDraftCandidateState {
            if suppressedCandidateIdentity == candidate.identity {
                let candidateItem = NSMenuItem(
                    title: "이 입력창에서 유지: \u{201c}\(candidate.displayPhrase)\u{201d}",
                    action: nil,
                    keyEquivalent: ""
                )
                candidateItem.isEnabled = false
                assistanceMenu.addItem(candidateItem)
            } else if currentDraftCandidatePanel.isVisible {
                let keepItem = NSMenuItem(
                    title: candidateHotKeys.isActive
                        ? "후보 유지: \u{201c}\(candidate.displayPhrase)\u{201d}  ⌃⌘K"
                        : "후보 유지: \u{201c}\(candidate.displayPhrase)\u{201d}",
                    action: #selector(keepCurrentDraftCandidateFromMenu),
                    keyEquivalent: ""
                )
                keepItem.target = self
                assistanceMenu.addItem(keepItem)

                let approveItem = NSMenuItem(
                    title: candidateHotKeys.isActive
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
        preview.isEnabled = enabled && currentAllowed
            && interactionState.isIdle
        menu.addItem(preview)

        let delete = NSMenuItem(
            title: "Whack & Delete Exact Phrase…",
            action: #selector(deleteExactPhrase),
            keyEquivalent: ""
        )
        delete.target = self
        delete.isEnabled = enabled && currentAllowed
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
        motionCapture.isEnabled = enabled && !localSessionDetectionEnabled
        menu.addItem(motionCapture)
        menu.addItem(.separator())

        for title in [
            "Native/browser input: macOS Accessibility (AX)",
            terminalServerReady
                ? "Terminal: authenticated Zsh transport ready"
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

    @objc private func toggleEnabled() {
        enabled.toggle()
        defaults.set(enabled, forKey: Preferences.enabled)
        if enabled {
            ephemeralProcesses.setAccepting(true)
            activateAutomaticDraftWatchIfNeeded()
        } else {
            disableLocalSessionDetection(restartSensor: false)
            previewSheet?.cancel()
            deleteSheet?.cancel()
            interactionState.cancel(.preview)
            interactionState.cancel(.delete)
            ephemeralProcesses.cancelAll(wait: false)
        }
        reconcileSensor()
    }

    @objc private func toggleWDSForCurrentApplication() {
        guard let target = currentTarget else { return }

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
            setStatus("손쉬운 사용 권한을 허용한 뒤 WDS 시작을 다시 누르세요")
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
        guard enabled,
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
            guard accepted, !target.application.isTerminated else {
                _ = target.application.activate(options: [.activateIgnoringOtherApps])
                self.setStatus("현재 초안 감시 상태를 바꾸지 않았습니다")
                return
            }

            if grantPersistentAccessOnAccept {
                self.enabled = true
                self.defaults.set(true, forKey: Preferences.enabled)
                self.ephemeralProcesses.setAccepting(true)
                self.allowedBundleIdentifiers.insert(target.bundleIdentifier)
                self.autoWatchBundleIdentifiers.insert(target.bundleIdentifier)
                self.persistAllowlist()
            } else {
                self.sessionWatchBundleIdentifiers.insert(target.bundleIdentifier)
            }
            guard self.enabled,
                  AXIsProcessTrusted(),
                  self.allowedBundleIdentifiers.contains(target.bundleIdentifier) else {
                _ = target.application.activate(options: [.activateIgnoringOtherApps])
                self.setStatus("WDS 시작 실패: 권한 또는 앱 허용 상태를 확인하세요")
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
                      self.enabled,
                      self.localSessionScope?.matches(target) == true else { return }
                self.reconcileSensor()
                self.setStatus("현재 초안 감시 중 • 로컬 • 토큰 0")
            }
        }
    }

    @objc private func showCurrentDraftCandidate() {
        guard let state = currentDraftCandidateState,
              suppressedCandidateIdentity != state.identity else { return }
        typingDismissedCandidateIdentity = nil
        scheduleCandidateInspection(for: state, delay: 0)
    }

    @objc private func keepCurrentDraftCandidateFromMenu() {
        guard currentDraftCandidatePanel.isVisible,
              let identity = currentDraftCandidateState?.identity else { return }
        keepCurrentDraftCandidate(identity)
    }

    @objc private func approveCurrentDraftCandidateFromMenu() {
        guard currentDraftCandidatePanel.isVisible,
              let identity = currentDraftCandidateState?.identity else { return }
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
    }

    private func clearCurrentLocalDraft() {
        currentLocalDraft = nil
        candidateDebounceIdentifier = nil
        interactionState.cancel(.candidateInspection)
        currentDraftCandidateState = nil
        suppressedCandidateIdentity = nil
        typingDismissedCandidateIdentity = nil
        dismissCurrentDraftCandidate()
    }

    private func shouldCaptureRawText(for target: TargetApplication) -> Bool {
        localSessionDetectionEnabled && localSessionScope?.matches(target) == true
    }

    private func shouldUseTextOnlySensor(for target: TargetApplication) -> Bool {
        shouldCaptureRawText(for: target) || !motionCaptureEnabled
    }

    private func currentDraftForCurrentTarget() -> LocalDraftSnapshot? {
        guard let target = currentTarget,
              shouldCaptureRawText(for: target),
              let draft = currentLocalDraft,
              draft.bundleIdentifier == target.bundleIdentifier,
              draft.processIdentifier == target.processIdentifier,
              sensorSession?.focusEpoch == draft.focusEpoch else { return nil }
        return draft
    }

    private func candidateState(for draft: LocalDraftSnapshot) -> CurrentDraftCandidateState? {
        // A user-registered dictionary phrase wins over the built-in analyzer's
        // guess; both yield the same candidate shape so the rest of the pipeline
        // (identity, panel, exact-range edit) is unchanged.
        let candidate = dictionaryMatcher.firstCandidate(in: draft.text, dictionary: phraseDictionary)
            ?? currentDraftAnalyzer.analyze(draft.text).first
        guard let candidate else { return nil }
        let source = draft.text as NSString
        let range = NSRange(
            location: candidate.range.location,
            length: candidate.range.length
        )
        guard range.location >= 0,
              range.length > 0,
              NSMaxRange(range) <= source.length,
              source.substring(with: range) == candidate.originalText else { return nil }

        return CurrentDraftCandidateState(
            identity: CurrentDraftCandidateIdentity(
                bundleIdentifier: draft.bundleIdentifier,
                processIdentifier: draft.processIdentifier,
                focusEpoch: draft.focusEpoch,
                range: candidate.range,
                originalText: candidate.originalText
            ),
            candidate: candidate
        )
    }

    private func refreshCurrentDraftCandidate() {
        guard let draft = currentDraftForCurrentTarget(),
              let state = candidateState(for: draft) else {
            candidateDebounceIdentifier = nil
            interactionState.cancel(.candidateInspection)
            currentDraftCandidateState = nil
            dismissCurrentDraftCandidate()
            if localSessionDetectionEnabled {
                setStatus("현재 초안 감시 중 • 안전한 후보 없음")
            }
            return
        }

        if currentDraftCandidateState?.identity == state.identity {
            currentDraftCandidateState = state
            if currentDraftCandidatePanel.isVisible {
                typingDismissedCandidateIdentity = state.identity
                dismissCurrentDraftCandidate()
                setStatus("계속 입력하여 후보 숨김 • 메뉴에서 다시 볼 수 있습니다")
            }
            return
        }

        candidateDebounceIdentifier = nil
        interactionState.cancel(.candidateInspection)
        dismissCurrentDraftCandidate()
        currentDraftCandidateState = state
        typingDismissedCandidateIdentity = nil
        guard suppressedCandidateIdentity != state.identity else {
            setStatus("\u{201c}\(state.displayPhrase)\u{201d} 유지 • 이 입력창에서는 다시 묻지 않음")
            return
        }
        scheduleCandidateInspection(for: state, delay: 0.4)
    }

    private func scheduleCandidateInspection(
        for state: CurrentDraftCandidateState,
        delay: TimeInterval
    ) {
        guard enabled,
              interactionState.isIdle,
              suppressedCandidateIdentity != state.identity,
              typingDismissedCandidateIdentity != state.identity else { return }

        let debounceIdentifier = UUID()
        candidateDebounceIdentifier = debounceIdentifier
        let identity = state.identity
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  self.candidateDebounceIdentifier == debounceIdentifier,
                  self.interactionState.isIdle,
                  self.currentDraftCandidateState?.identity == identity,
                  self.suppressedCandidateIdentity != identity,
                  self.typingDismissedCandidateIdentity != identity,
                  let target = self.currentTarget,
                  target.bundleIdentifier == identity.bundleIdentifier,
                  target.processIdentifier == identity.processIdentifier,
                  self.deleteTargetIsReady(target)
            else { return }
            self.candidateDebounceIdentifier = nil
            self.inspectForCandidate(
                state: state,
                target: target
            )
        }
    }

    private func inspectForCandidate(
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
                    state: state,
                    target: target,
                    interaction: interaction
                )
            }
        }
    }

    private func finishCandidateInspection(
        _ result: CandidateInspectionResult,
        state: CurrentDraftCandidateState,
        target: TargetApplication,
        interaction: InteractionToken
    ) {
        guard interactionState.finish(interaction) else { return }
        guard enabled,
              currentDraftCandidateState?.identity == state.identity,
              suppressedCandidateIdentity != state.identity,
              typingDismissedCandidateIdentity != state.identity,
              let draft = currentDraftForCurrentTarget(),
              candidateState(for: draft)?.identity == state.identity,
              currentTarget?.processIdentifier == target.processIdentifier,
              deleteTargetIsReady(target)
        else { return }

        switch result {
        case .failure(let status):
            setStatus(status)
        case .success(let rectangle):
            let replacement = state.candidate.replacement
            let keyboardShortcutsAvailable = candidateHotKeys.activate(
                onApprove: { [weak self] in
                    self?.approveCurrentDraftCandidate(state.identity)
                },
                onKeep: { [weak self] in
                    self?.keepCurrentDraftCandidate(state.identity)
                },
                onReplace: replacement.map { value in
                    { [weak self] in
                        self?.approveCurrentDraftCandidate(state.identity, replacement: value)
                    }
                }
            )
            currentDraftCandidatePanel.present(
                phrase: state.displayPhrase,
                targetBounds: rectangle,
                keyboardShortcutsAvailable: keyboardShortcutsAvailable,
                replacement: replacement,
                onApprove: { [weak self] in
                    self?.approveCurrentDraftCandidate(state.identity)
                },
                onKeep: { [weak self] in
                    self?.keepCurrentDraftCandidate(state.identity)
                },
                onReplace: replacement.map { value in
                    { [weak self] in
                        self?.approveCurrentDraftCandidate(state.identity, replacement: value)
                    }
                }
            )
            let hint: String
            if replacement != nil {
                hint = keyboardShortcutsAvailable
                    ? "후보 \u{201c}\(state.displayPhrase)\u{201d} • ⌃⌘R 치환 / ⌃⌘⌫ 날리기"
                    : "후보 \u{201c}\(state.displayPhrase)\u{201d} • ‘치환’ 또는 ‘날리기’ 선택"
            } else if keyboardShortcutsAvailable {
                hint = "후보 \u{201c}\(state.displayPhrase)\u{201d} • ⌃⌘⌫로 날리기"
            } else {
                hint = "후보 \u{201c}\(state.displayPhrase)\u{201d} • ‘날리기’를 누르면 삭제"
            }
            setStatus(hint)
        }
    }

    private func keepCurrentDraftCandidate(_ identity: CurrentDraftCandidateIdentity) {
        guard currentDraftCandidateState?.identity == identity else {
            dismissCurrentDraftCandidate()
            return
        }
        suppressedCandidateIdentity = identity
        candidateDebounceIdentifier = nil
        interactionState.cancel(.candidateInspection)
        dismissCurrentDraftCandidate()
        setStatus("\u{201c}\(identity.originalText.trimmingCharacters(in: .whitespacesAndNewlines))\u{201d} 유지 • 이 입력창에서는 다시 묻지 않음")
    }

    private func approveCurrentDraftCandidate(
        _ identity: CurrentDraftCandidateIdentity,
        replacement: String? = nil
    ) {
        let isReplace = replacement != nil
        guard enabled,
              interactionState.isIdle,
              let draft = currentDraftForCurrentTarget(),
              let latestState = candidateState(for: draft),
              latestState.identity == identity,
              // A replace must still be backed by the same registered replacement.
              (!isReplace || latestState.candidate.replacement == replacement),
              let target = currentTarget,
              target.bundleIdentifier == identity.bundleIdentifier,
              target.processIdentifier == identity.processIdentifier
        else {
            dismissCurrentDraftCandidate()
            setStatus("후보가 바뀌어 편집하지 않았습니다")
            resumeCandidatePresentationIfPossible()
            return
        }

        candidateDebounceIdentifier = nil
        dismissCurrentDraftCandidate()

        guard let interaction = interactionState.begin(.delete) else { return }
        setStatus("승인한 후보를 다시 확인 중…")
        _ = target.application.activate(options: [.activateIgnoringOtherApps])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self,
                  self.interactionState.owns(interaction),
                  self.deleteTargetIsReady(target),
                  let latestDraft = self.currentDraftForCurrentTarget(),
                  self.candidateState(for: latestDraft)?.identity == identity else {
                self?.interactionState.finish(interaction)
                self?.setStatus("후보가 바뀌어 편집하지 않았습니다")
                self?.resumeCandidatePresentationIfPossible()
                return
            }
            self.inspectForDelete(
                phrase: identity.originalText,
                target: target,
                interaction: interaction,
                replacement: replacement
            )
        }
    }

    @objc private func testEffect() {
        guard interactionState.isIdle,
              !currentDraftCandidatePanel.isVisible
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
        guard enabled,
              interactionState.isIdle,
              let target = currentTarget,
              allowedBundleIdentifiers.contains(target.bundleIdentifier)
        else { return }

        candidateDebounceIdentifier = nil
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
                if self.enabled {
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
                guard self.enabled,
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
        guard enabled,
              interactionState.isIdle,
              let target = currentTarget,
              allowedBundleIdentifiers.contains(target.bundleIdentifier)
        else { return }

        candidateDebounceIdentifier = nil
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
                if self.enabled {
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
                guard self.deleteTargetIsReady(target) else {
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
        guard enabled, !localSessionDetectionEnabled else { return }
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

    private func loadSavingsLedger() -> SavingsLedger {
        guard let data = defaults.data(forKey: Preferences.tokenSavingsLedger) else {
            return SavingsLedger()
        }
        if let ledger = try? JSONDecoder().decode(SavingsLedger.self, from: data) {
            return ledger
        }
        // Data exists but no longer decodes. Preserve the raw blob under a
        // backup key so starting fresh does not irrecoverably destroy a lifetime
        // total that a later migration might recover, instead of overwriting it
        // on the next deletion.
        defaults.set(data, forKey: Preferences.tokenSavingsLedgerCorruptBackup)
        return SavingsLedger()
    }

    private func persistSavingsLedger() {
        guard let data = try? JSONEncoder().encode(savingsLedger) else { return }
        defaults.set(data, forKey: Preferences.tokenSavingsLedger)
    }

    /// Adds one confirmed edit to the local savings tally. `removed` is the exact
    /// text taken out of the draft; `replacement` is what replaced it ("" for a
    /// pure deletion). The saving is the estimated token difference, so a
    /// replacement only counts the net tokens avoided. Called only from the
    /// single-fire success path, on the main thread. Returns the net estimate so
    /// the caller can show immediate feedback.
    @discardableResult
    private func recordSaving(removed: String, replacement: String = "") -> Int {
        let saved = max(0, TokenEstimator.estimate(removed) - TokenEstimator.estimate(replacement))
        savingsLedger.record(savedTokens: saved, periodKey: SavingsPeriod.weekKey(for: Date()))
        persistSavingsLedger()
        return saved
    }

    private func loadPhraseDictionary() -> PhraseDictionary {
        guard let data = defaults.data(forKey: Preferences.phraseDictionary) else {
            return PhraseDictionary()
        }
        if let dictionary = try? JSONDecoder().decode(PhraseDictionary.self, from: data) {
            return dictionary
        }
        // These phrases are the user's own authored content, so preserve the
        // undecodable blob under a backup key rather than letting the next write
        // overwrite it with an empty dictionary.
        defaults.set(data, forKey: Preferences.phraseDictionaryCorruptBackup)
        return PhraseDictionary()
    }

    private func persistPhraseDictionary() {
        guard let data = try? JSONEncoder().encode(phraseDictionary) else { return }
        defaults.set(data, forKey: Preferences.phraseDictionary)
    }

    @objc private func addPhraseEntry() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "말버릇 추가"
        alert.informativeText = "전송 전에 초안에서 찾을 문구를 입력하세요. 바꿀 말을 적으면 치환, 비우면 삭제 후보가 됩니다."
        alert.addButton(withTitle: "추가")
        alert.addButton(withTitle: "취소")

        let phraseField = NSTextField(frame: NSRect(x: 0, y: 30, width: 320, height: 24))
        phraseField.placeholderString = "찾을 문구 (예: 혹시 가능하시다면)"
        let replacementField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        replacementField.placeholderString = "바꿀 말 (선택 · 비우면 삭제)"
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 58))
        container.addSubview(phraseField)
        container.addSubview(replacementField)
        alert.accessoryView = container
        alert.window.initialFirstResponder = phraseField

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            let entry = try DictionaryEntry(
                id: UUID().uuidString,
                rawPhrase: phraseField.stringValue,
                replacement: replacementField.stringValue
            )
            if phraseDictionary.add(entry) {
                persistPhraseDictionary()
                setStatus("말버릇 추가: \u{201c}\(entry.phrase)\u{201d}")
            } else {
                setStatus("이미 등록된 문구입니다")
            }
        } catch DictionaryEntryError.emptyPhrase {
            setStatus("문구가 비어 있어 추가하지 않았습니다")
        } catch DictionaryEntryError.noOpReplacement {
            setStatus("찾을 문구와 바꿀 말이 같아 추가하지 않았습니다")
        } catch {
            setStatus("문구를 추가하지 못했습니다")
        }
    }

    @objc private func togglePhraseEntry(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let entry = phraseDictionary.entries.first(where: { $0.id == id }) else { return }
        phraseDictionary.setActive(!entry.isActive, id: id)
        persistPhraseDictionary()
    }

    @objc private func removePhraseEntry(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        phraseDictionary.remove(id: id)
        persistPhraseDictionary()
    }

    private func frontmostApplicationChanged(_ application: NSRunningApplication?) {
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
        guard enabled,
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
        guard enabled else {
            stopSensor(wait: false)
            setStatus("꺼짐 — 위의 ‘WDS 시작’을 누르세요")
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
            setStatus("현재 앱에서 ‘WDS 시작’을 누르세요")
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
                currentLocalDraft = text.isEmpty ? nil : LocalDraftSnapshot(
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
        target: TargetApplication,
        interaction: InteractionToken,
        replacement: String? = nil
    ) {
        guard let executableURL = helperURL(named: "wds-ax-bridge") else {
            interactionState.finish(interaction)
            setStatus("편집 브리지를 찾을 수 없습니다")
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
                    replacement: replacement ?? "",
                    expectedProcessIdentifier: target.processIdentifier
                ) {
                case .success(let inspection):
                    result = .success(inspection)
                case .failure(let failure):
                    result = .failure(failure.status)
                }
            } catch {
                result = .failure("검사가 취소됨")
            }

            DispatchQueue.main.async { [weak self] in
                self?.finishDeleteInspection(
                    result,
                    phrase: phrase,
                    target: target,
                    interaction: interaction,
                    replacement: replacement
                )
            }
        }
    }

    private func finishDeleteInspection(
        _ result: DeleteInspectionResult,
        phrase: String,
        target: TargetApplication,
        interaction: InteractionToken,
        replacement: String? = nil
    ) {
        guard interactionState.owns(interaction) else { return }
        guard enabled, allowedBundleIdentifiers.contains(target.bundleIdentifier) else {
            interactionState.finish(interaction)
            setStatus("편집이 취소됨")
            resumeCandidatePresentationIfPossible()
            return
        }

        switch result {
        case .failure(let status):
            interactionState.finish(interaction)
            setStatus(status)
            resumeCandidatePresentationIfPossible()
        case .success(let inspection):
            setStatus(replacement != nil ? "치환 전 대상을 다시 확인 중…" : "삭제 전 대상을 다시 확인 중…")
            _ = target.application.activate(options: [.activateIgnoringOtherApps])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, self.interactionState.owns(interaction) else { return }
                guard self.deleteTargetIsReady(target),
                      inspection.processIdentifier == target.processIdentifier
                else {
                    self.interactionState.finish(interaction)
                    self.setStatus("편집 취소됨: 대상 또는 포커스가 바뀜")
                    self.resumeCandidatePresentationIfPossible()
                    return
                }
                self.executeDelete(
                    phrase: phrase,
                    inspection: inspection,
                    target: target,
                    interaction: interaction,
                    replacement: replacement
                )
            }
        }
    }

    private func executeDelete(
        phrase: String,
        inspection: SafeDeleteInspection,
        target: TargetApplication,
        interaction: InteractionToken,
        replacement: String? = nil
    ) {
        guard let executableURL = helperURL(named: "wds-ax-bridge") else {
            interactionState.finish(interaction)
            setStatus("편집 브리지를 찾을 수 없습니다")
            resumeCandidatePresentationIfPossible()
            return
        }

        let isReplace = replacement != nil
        setStatus(isReplace ? "바뀌지 않은 정확한 범위를 치환 중…" : "바뀌지 않은 정확한 범위를 삭제 중…")
        // For replace, the bridge reads target and replacement from one stdin
        // stream, split on a single NUL byte, so neither is passed as an argument.
        let editCommand = isReplace ? "replace" : "delete"
        let stdinFlag = isReplace ? "--edit-stdin" : "--target-stdin"
        let stdinData = isReplace ? Data((phrase + "\u{0}" + (replacement ?? "")).utf8) : Data(phrase.utf8)
        let registry = ephemeralProcesses
        previewQueue.async { [weak self] in
            let process = Process()
            let inputPipe = Pipe()
            let outputPipe = Pipe()
            process.executableURL = executableURL
            process.arguments = [
                editCommand, stdinFlag,
                "--bundle-id", target.bundleIdentifier,
                "--expected-value-sha256", inspection.valueSHA256,
                "--expected-pid", String(inspection.processIdentifier),
                "--expected-range-location", String(inspection.rangeLocation),
                "--expected-range-length", String(inspection.rangeLength),
            ]
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
                try inputPipe.fileHandleForWriting.write(contentsOf: stdinData)
                try inputPipe.fileHandleForWriting.close()
                let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let validation = isReplace
                    ? SafeDeleteResponseValidator.validateReplacement(output, against: inspection)
                    : SafeDeleteResponseValidator.validateDeletion(output, against: inspection)
                switch validation {
                case .success:
                    result = .success
                case .failure(let failure):
                    result = .failure(failure.status)
                }
            } catch {
                result = .failure(isReplace ? "안전 치환이 취소됨" : "안전 삭제가 취소됨")
            }

            DispatchQueue.main.async { [weak self] in
                self?.finishDelete(
                    result,
                    phrase: phrase,
                    inspection: inspection,
                    target: target,
                    interaction: interaction,
                    replacement: replacement
                )
            }
        }
    }

    private func finishDelete(
        _ result: DeleteExecutionResult,
        phrase: String,
        inspection: SafeDeleteInspection,
        target: TargetApplication,
        interaction: InteractionToken,
        replacement: String? = nil
    ) {
        guard interactionState.finish(interaction) else { return }

        // The edit physically succeeded at the AX layer, so count the saving even
        // if WDS was disabled or the target de-allowlisted during the in-flight
        // edit. Accounting must reflect what actually changed in the draft; the
        // enabled/allowlist gate below only governs the overlay effect.
        let isReplace = replacement != nil
        var savedTokens = 0
        if case .success = result {
            savedTokens = recordSaving(removed: phrase, replacement: replacement ?? "")
        }

        guard enabled, allowedBundleIdentifiers.contains(target.bundleIdentifier) else { return }

        switch result {
        case .success:
            let action = isReplace ? "치환" : "삭제"
            let completionStatus = savedTokens > 0
                ? "정확한 문구 \(action) • 약 \(savedTokens)토큰 절약(추정)"
                : "정확한 문구 \(action) 완료"
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
                startingStatus: "정확한 문구 \(action); 효과 재생 중",
                completionStatus: completionStatus,
                failureStatus: "문구는 \(action)됐지만 효과 확인 실패"
            )
        case .failure(let status):
            setStatus(status)
            resumeCandidatePresentationIfPossible()
        }
    }

    private func deleteTargetIsReady(_ target: TargetApplication) -> Bool {
        enabled
            && !target.application.isTerminated
            && target.application.isActive
            && allowedBundleIdentifiers.contains(target.bundleIdentifier)
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
    }

    private func finishPreviewInspection(
        _ result: PreviewInspectionResult,
        phrase: String,
        target: TargetApplication,
        interaction: InteractionToken
    ) {
        guard interactionState.finish(interaction) else { return }
        guard enabled,
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
        guard let state = currentDraftCandidateState,
              suppressedCandidateIdentity != state.identity,
              typingDismissedCandidateIdentity != state.identity,
              !currentDraftCandidatePanel.isVisible,
              interactionState.isIdle
        else { return }
        scheduleCandidateInspection(for: state, delay: 0.2)
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
