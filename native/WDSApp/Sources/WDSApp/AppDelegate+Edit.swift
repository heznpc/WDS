import ApplicationServices
import AppKit
import CoreGraphics
import Darwin
import Foundation
import WDSAppCore
import WDSWhackCore

/// Accessibility-bridge inspect, delete, replace, and preview execution.
extension AppDelegate {
    func inspectForPreview(
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

    func inspectForDelete(
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

    func finishDeleteInspection(
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

    func executeDelete(
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

    func finishDelete(
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
            savedTokens = savingsStore.record(removed: phrase, replacement: replacement ?? "")
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

    func deleteTargetIsReady(_ target: TargetApplication) -> Bool {
        enabled
            && !target.application.isTerminated
            && target.application.isActive
            && allowedBundleIdentifiers.contains(target.bundleIdentifier)
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
    }

    func finishPreviewInspection(
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
}
