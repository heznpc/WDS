import ApplicationServices
import AppKit
import CoreGraphics
import Darwin
import Foundation
import WDSAppCore
import WDSWhackCore

/// Whack overlay rendering and watchdog.
extension AppDelegate {
    func playOverlay(
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

    func scheduleOverlayWatchdog(for process: Process) {
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
}
