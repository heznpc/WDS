import ApplicationServices
import AppKit
import CoreGraphics
import Darwin
import Foundation
import WDSAppCore
import WDSWhackCore

/// Permission requests, motion capture, and allow-list persistence.
extension AppDelegate {
    @objc func quitApplication() {
        NSApp.terminate(nil)
    }

    @objc func requestAccessibilityPermission() {
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

    func pollAccessibilityPermission(
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

    @objc func requestMouseEffectPermission() {
        _ = CGRequestListenEventAccess()
        setStatus("Optional mouse-effect permission request opened")
    }

    @objc func toggleMotionCapture() {
        guard enabled, !localSessionDetectionEnabled else { return }
        motionCaptureEnabled.toggle()
        stopSensor(wait: false)
        reconcileSensor()
        setStatus(motionCaptureEnabled
            ? "Recent mouse motion enabled for this launch"
            : "Recent mouse motion disabled")
    }

    func persistAllowlist() {
        defaults.set(allowedBundleIdentifiers.sorted(), forKey: Preferences.allowedBundleIdentifiers)
        defaults.set(
            autoWatchBundleIdentifiers.sorted(),
            forKey: Preferences.autoWatchBundleIdentifiers
        )
    }
}
