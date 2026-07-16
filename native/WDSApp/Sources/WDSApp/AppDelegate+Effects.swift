import ApplicationServices
import AppKit
import CoreGraphics
import Darwin
import Foundation
import WDSAppCore
import WDSWhackCore

/// Effect test, focused-input preview, and manual delete triggers.
extension AppDelegate {
    @objc func testEffect() {
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

    @objc func previewFocusedInput() {
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

    @objc func deleteExactPhrase() {
        beginDeleteExactPhrase(initialPhrase: "")
    }

    func beginDeleteExactPhrase(initialPhrase: String) {
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
}
