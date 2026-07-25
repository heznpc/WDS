import ApplicationServices
import AppKit
import CoreGraphics
import Darwin
import Foundation
import WDSAppCore
import WDSWhackCore

/// Current-draft candidate detection, inspection, and review pipeline.
extension AppDelegate {
    func dismissCurrentDraftCandidate() {
        candidateHotKeys.deactivate()
        currentDraftCandidatePanel.dismiss()
    }

    func clearCurrentLocalDraft() {
        currentLocalDraft = nil
        candidateDebounceIdentifier = nil
        interactionState.cancel(.candidateInspection)
        currentDraftCandidateState = nil
        suppressedCandidateIdentity = nil
        typingDismissedCandidateIdentity = nil
        dismissCurrentDraftCandidate()
    }

    func shouldCaptureRawText(for target: TargetApplication) -> Bool {
        localSessionDetectionEnabled && localSessionScope?.matches(target) == true
    }

    func shouldUseTextOnlySensor(for target: TargetApplication) -> Bool {
        shouldCaptureRawText(for: target) || !motionCaptureEnabled
    }

    func currentDraftForCurrentTarget() -> LocalDraftSnapshot? {
        guard let target = currentTarget,
              shouldCaptureRawText(for: target),
              let draft = currentLocalDraft,
              draft.bundleIdentifier == target.bundleIdentifier,
              draft.processIdentifier == target.processIdentifier,
              sensorSession?.focusEpoch == draft.focusEpoch else { return nil }
        return draft
    }

    func candidateState(for draft: LocalDraftSnapshot) -> CurrentDraftCandidateState? {
        // A user-registered dictionary phrase wins over the built-in analyzer's
        // guess; both yield the same candidate shape so the rest of the pipeline
        // (identity, panel, exact-range edit) is unchanged.
        let candidate = dictionaryMatcher.firstCandidate(in: draft.text, dictionary: dictionaryStore.dictionary)
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

    func refreshCurrentDraftCandidate() {
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

    func scheduleCandidateInspection(
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

    func inspectForCandidate(
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

    func finishCandidateInspection(
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

            // An entry the user flagged for automatic apply skips the review
            // panel, iPhone text-replacement style. approveCurrentDraftCandidate
            // re-validates the identity and runs the full precondition-checked
            // edit path, so only the confirmation step is skipped. A per-focus
            // budget stops indirect replacement cycles from editing forever.
            if state.candidate.autoApply {
                let budgetKey = "\(state.identity.processIdentifier):\(state.identity.focusEpoch)"
                if autoApplyBudgetKey != budgetKey {
                    autoApplyBudgetKey = budgetKey
                    autoApplyBudgetUsed = 0
                }
                if autoApplyBudgetUsed < 20 {
                    autoApplyBudgetUsed += 1
                    setStatus("등록 문구 자동 정리 중: \u{201c}\(state.displayPhrase)\u{201d}")
                    approveCurrentDraftCandidate(state.identity, replacement: replacement)
                    return
                }
                setStatus("자동 정리 한도 도달 • 이 후보는 직접 확인해 주세요")
            }

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

    func keepCurrentDraftCandidate(_ identity: CurrentDraftCandidateIdentity) {
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

    func approveCurrentDraftCandidate(
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
}
