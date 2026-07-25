import ApplicationServices
import AppKit
import CoreGraphics
import Darwin
import Foundation
import WDSAppCore
import WDSWhackCore

/// Menu action handlers: engine and app toggles, the allow-list, and watch consent.
extension AppDelegate {
    @objc func toggleEnabled() {
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

    @objc func toggleWDSForCurrentApplication() {
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

    @objc func allowCurrentApplication() {
        guard let currentTarget else { return }
        allowedBundleIdentifiers.insert(currentTarget.bundleIdentifier)
        persistAllowlist()
        reconcileSensor()
    }

    @objc func removeAllowedApplication(_ sender: NSMenuItem) {
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

    @objc func toggleLocalSessionDetection() {
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

    func presentCurrentDraftWatchConsent(
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

    @objc func showCurrentDraftCandidate() {
        guard let state = currentDraftCandidateState,
              suppressedCandidateIdentity != state.identity else { return }
        typingDismissedCandidateIdentity = nil
        scheduleCandidateInspection(for: state, delay: 0)
    }

    @objc func keepCurrentDraftCandidateFromMenu() {
        guard currentDraftCandidatePanel.isVisible,
              let identity = currentDraftCandidateState?.identity else { return }
        keepCurrentDraftCandidate(identity)
    }

    @objc func approveCurrentDraftCandidateFromMenu() {
        guard currentDraftCandidatePanel.isVisible,
              let identity = currentDraftCandidateState?.identity else { return }
        approveCurrentDraftCandidate(identity)
    }

    @objc func forgetLocalSessionData() {
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

    func disableLocalSessionDetection(restartSensor: Bool) {
        sessionDetectionConsentSheet?.cancel()
        sessionDetectionConsentSheet = nil
        localSessionDetectionEnabled = false
        localSessionScope = nil
        resetLocalSessionData()
        stopSensor(wait: false)
        if restartSensor { reconcileSensor() }
    }

    func resetLocalSessionData() {
        clearCurrentLocalDraft()
    }
}
