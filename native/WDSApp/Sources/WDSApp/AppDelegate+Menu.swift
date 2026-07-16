import ApplicationServices
import AppKit
import CoreGraphics
import Darwin
import Foundation
import WDSAppCore
import WDSWhackCore

/// Status-bar menu construction.
extension AppDelegate {
    func rebuildMenu() {
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

        let weeklyTokens = savingsStore.weeklyTokens
        let savingsTitle: String
        if savingsStore.lifetimeTokens == 0 {
            savingsTitle = "이번 주 정리한 토큰: 아직 없음 (추정)"
        } else {
            savingsTitle = "이번 주 약 \(weeklyTokens)토큰 정리 · 누적 \(savingsStore.lifetimeTokens)토큰 (추정)"
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
        if dictionaryStore.entries.isEmpty {
            let empty = NSMenuItem(title: "등록된 문구 없음", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            dictionaryMenu.addItem(empty)
        } else {
            for entry in dictionaryStore.entries {
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
}
