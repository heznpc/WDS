import ApplicationServices
import AppKit
import CoreGraphics
import Darwin
import Foundation
import WDSAppCore
import WDSWhackCore

/// Sensor lifecycle and JSON-Lines event handling.
extension AppDelegate {
    func frontmostApplicationChanged(_ application: NSRunningApplication?) {
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

    func activateAutomaticDraftWatchIfNeeded() {
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

    func reconcileSensor() {
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

    func startSensor(for target: TargetApplication) {
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

    func stopSensor(wait: Bool) {
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

    func handleSensorBatch(_ batch: JSONLineBatch, sessionIdentifier: UUID) {
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

    func handleSensorEvent(_ event: [String: Any], sessionIdentifier: UUID) {
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

    func rejectSensorSession(_ session: SensorSession, status: String) {
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

    func sensorEventProcessIdentifier(_ event: [String: Any]) -> pid_t? {
        guard let value = sensorEventInteger(event["pid"]),
              value > 0, value <= Int(Int32.max) else { return nil }
        return pid_t(value)
    }

    func sensorEventInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite,
              double.rounded(.towardZero) == double,
              double >= Double(Int.min), double <= Double(Int.max) else { return nil }
        return Int(double)
    }

    func sensorTerminated(sessionIdentifier: UUID) {
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
}
