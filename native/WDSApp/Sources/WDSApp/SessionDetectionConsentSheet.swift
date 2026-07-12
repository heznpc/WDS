import AppKit

final class SessionDetectionConsentSheet {
    private var anchorWindow: NSWindow?
    private var alert: NSAlert?
    private var completion: ((Bool) -> Void)?

    func present(
        for targetName: String,
        automaticallyResume: Bool,
        completion: @escaping (Bool) -> Void
    ) {
        self.completion = completion

        let anchor = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 84),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        anchor.title = "WDS Current-Draft Watch"
        anchor.isReleasedWhenClosed = false

        let label = NSTextField(labelWithString: automaticallyResume
            ? "\(targetName) • 현재 입력창 • 앱이 전면일 때 자동 감시"
            : "\(targetName) • 현재 입력창 • 이번 WDS 실행 동안만")
        label.frame = NSRect(x: 20, y: 31, width: 480, height: 22)
        label.alignment = .center
        anchor.contentView?.addSubview(label)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "\(targetName)에서 WDS를 시작할까요?"
        alert.informativeText = automaticallyResume
            ? "WDS가 켜져 있는 동안 이 앱이 전면에 오면 일반 입력창의 현재 초안만 메모리에서 로컬 분석합니다. WDS나 이 앱을 다시 실행해도 자동 감시가 재개됩니다. 초안·후보·사용자 프로파일은 저장하거나 전송하지 않으며, 직접 \u{201c}날리기\u{201d}를 승인하기 전에는 글자를 바꾸지 않습니다. 저장되는 것은 앱 식별자뿐이며 언제든 허용 목록에서 해제할 수 있습니다."
            : "WDS는 이 앱의 일반 입력창에 포커스가 있을 때 현재 초안만 메모리에서 로컬 분석합니다. 사용자 프로파일을 학습하거나 초안을 저장·전송하지 않으며, \u{201c}날리기\u{201d}를 직접 누르기 전에는 글자를 바꾸지 않습니다. 이 감시는 WDS를 종료하면 꺼집니다."
        alert.addButton(withTitle: automaticallyResume ? "이 앱 자동 감시 허용" : "이 앱에서 시작")
        alert.addButton(withTitle: "취소")

        anchorWindow = anchor
        self.alert = alert
        NSApp.activate(ignoringOtherApps: true)
        anchor.center()
        anchor.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self, weak anchor] in
            guard let self, let anchor else { return }
            alert.beginSheetModal(for: anchor) { [weak self] response in
                self?.finish(response == .alertFirstButtonReturn)
            }
        }
    }

    func cancel() {
        guard let anchorWindow, let alert else { return }
        anchorWindow.endSheet(alert.window, returnCode: .cancel)
    }

    private func finish(_ accepted: Bool) {
        anchorWindow?.orderOut(nil)
        anchorWindow = nil
        alert = nil
        let completion = completion
        self.completion = nil
        completion?(accepted)
    }
}
