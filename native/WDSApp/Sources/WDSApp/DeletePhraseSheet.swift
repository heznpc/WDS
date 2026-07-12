import AppKit

final class DeletePhraseSheet {
    private var anchorWindow: NSWindow?
    private var alert: NSAlert?
    private var phraseField: NSTextField?
    private var completion: ((String?) -> Void)?

    func present(
        for targetName: String,
        initialPhrase: String = "",
        completion: @escaping (String?) -> Void
    ) {
        self.completion = completion

        let anchor = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 84),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        anchor.title = "WDS Safe Delete"
        anchor.isReleasedWhenClosed = false
        let label = NSTextField(labelWithString: "Delete only from: \(targetName)")
        label.frame = NSRect(x: 20, y: 31, width: 460, height: 22)
        label.alignment = .center
        anchor.contentView?.addSubview(label)

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        field.placeholderString = "Exact phrase to delete from the focused input"
        field.stringValue = initialPhrase

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Whack & Delete Exact Phrase"
        alert.informativeText = "WDS will delete exactly one occurrence only if the full draft, app process, focus, and UTF-16 range are unchanged. It never presses Enter or submits the message."
        alert.accessoryView = field
        let deleteButton = alert.addButton(withTitle: "Whack & Delete")
        deleteButton.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")

        anchorWindow = anchor
        self.alert = alert
        phraseField = field

        NSApp.activate(ignoringOtherApps: true)
        anchor.center()
        anchor.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self, weak anchor] in
            guard let self, let anchor else { return }
            anchor.makeFirstResponder(field)
            field.selectText(nil)
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
