import AppKit
import Foundation

/// A modal sheet that collects one exact phrase for a preview-only overlay. It
/// never deletes or submits text.
final class PreviewPhraseSheet {
    private var anchorWindow: NSWindow?
    private var alert: NSAlert?
    private var phraseField: NSTextField?
    private var completion: ((String?) -> Void)?

    func present(for targetName: String, completion: @escaping (String?) -> Void) {
        self.completion = completion

        let anchor = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 84),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        anchor.title = "WDS Preview"
        anchor.isReleasedWhenClosed = false
        let label = NSTextField(labelWithString: "Preview target: \(targetName)")
        label.frame = NSRect(x: 20, y: 31, width: 420, height: 22)
        label.alignment = .center
        anchor.contentView?.addSubview(label)

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 390, height: 24))
        field.placeholderString = "Exact phrase in the focused input"

        let alert = NSAlert()
        alert.messageText = "Preview focused input effect"
        alert.informativeText = "Enter the exact phrase once. WDS will inspect its Accessibility range and play a visual overlay only—it will not delete or submit text."
        alert.accessoryView = field
        alert.addButton(withTitle: "Preview")
        alert.addButton(withTitle: "Cancel")

        anchorWindow = anchor
        self.alert = alert
        phraseField = field

        NSApp.activate(ignoringOtherApps: true)
        anchor.center()
        anchor.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self, weak anchor] in
            guard let self, let anchor else { return }
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
