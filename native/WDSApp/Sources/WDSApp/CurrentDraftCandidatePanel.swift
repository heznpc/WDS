import AppKit
import CoreGraphics

/// A small, non-activating review surface anchored near the candidate text.
/// It never edits the target directly; the app delegate owns every safety check
/// and performs the edit only after `onApprove` fires.
final class CurrentDraftCandidatePanel: NSObject {
    private var panel: NSPanel?
    private var onApprove: (() -> Void)?
    private var onKeep: (() -> Void)?

    var isVisible: Bool { panel?.isVisible == true }

    func present(
        phrase: String,
        replacement: String = "",
        targetBounds: CGRect,
        keyboardShortcutsAvailable: Bool,
        onApprove: @escaping () -> Void,
        onKeep: @escaping () -> Void
    ) {
        dismiss()
        self.onApprove = onApprove
        self.onKeep = onKeep

        let compactPhrase = phrase
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let isCorrection = !replacement.isEmpty
        let labelText = isCorrection
            ? "WDS  \(compactPhrase) → \(replacement)"
            : "WDS  \u{201c}\(compactPhrase)\u{201d} 덜어낼까요?"
        let measuredLabelWidth = ceil((labelText as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)]
        ).width)
        let controlsWidth: CGFloat = keyboardShortcutsAvailable ? 218 : 164
        let width = min(540, max(360, measuredLabelWidth + controlsWidth))
        let size = NSSize(width: width, height: 52)
        let frame = Self.panelFrame(size: size, targetBounds: targetBounds)

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.ignoresMouseEvents = false

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true

        let label = NSTextField(labelWithString: labelText)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.frame = NSRect(x: 15, y: 16, width: width - controlsWidth, height: 20)
        label.toolTip = isCorrection ? "승인하면 표시된 문구로 고칩니다" : "승인하면 표시된 구간만 덜어냅니다"
        background.addSubview(label)

        let keepButton = NSButton(
            title: keyboardShortcutsAvailable ? "유지  ⌃⌘K" : "유지",
            target: self,
            action: #selector(keepPressed)
        )
        keepButton.bezelStyle = .rounded
        keepButton.controlSize = .small
        keepButton.frame = NSRect(
            x: keyboardShortcutsAvailable ? width - 196 : width - 142,
            y: 13,
            width: keyboardShortcutsAvailable ? 94 : 56,
            height: 26
        )
        keepButton.toolTip = keyboardShortcutsAvailable
            ? "⌃⌘K • 이 입력창에서는 같은 후보를 다시 띄우지 않습니다"
            : "이 입력창에서는 같은 후보를 다시 띄우지 않습니다"
        keepButton.setAccessibilityLabel("후보 유지")
        background.addSubview(keepButton)

        let approveButton = NSButton(
            title: (isCorrection ? "고치기" : "날리기") + (keyboardShortcutsAvailable ? "  ⌃⌘⌫" : ""),
            target: self,
            action: #selector(approvePressed)
        )
        approveButton.bezelStyle = .rounded
        approveButton.controlSize = .small
        approveButton.keyEquivalent = ""
        approveButton.frame = NSRect(
            x: keyboardShortcutsAvailable ? width - 96 : width - 80,
            y: 13,
            width: keyboardShortcutsAvailable ? 82 : 66,
            height: 26
        )
        approveButton.toolTip = "초안과 범위를 다시 확인한 뒤 승인한 편집만 적용합니다"
        approveButton.setAccessibilityLabel(isCorrection ? "후보 고치기" : "후보 날리기")
        background.addSubview(approveButton)

        panel.contentView = background
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        onApprove = nil
        onKeep = nil
    }

    @objc private func approvePressed() {
        let completion = onApprove
        completion?()
    }

    @objc private func keepPressed() {
        let completion = onKeep
        completion?()
    }

    private static func panelFrame(size: NSSize, targetBounds: CGRect) -> NSRect {
        let mainDisplayHeight = CGDisplayBounds(CGMainDisplayID()).height
        let target = NSRect(
            x: targetBounds.minX,
            y: mainDisplayHeight - targetBounds.minY - targetBounds.height,
            width: targetBounds.width,
            height: targetBounds.height
        )
        let targetCenter = NSPoint(x: target.midX, y: target.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(targetCenter) })
            ?? NSScreen.main
        let available = screen?.visibleFrame ?? NSRect(
            x: target.minX - 500,
            y: target.minY - 500,
            width: 1_000,
            height: 1_000
        )

        var x = target.midX - size.width / 2
        var y = target.maxY + 10
        if y + size.height > available.maxY {
            y = target.minY - size.height - 10
        }
        x = min(max(x, available.minX + 8), available.maxX - size.width - 8)
        y = min(max(y, available.minY + 8), available.maxY - size.height - 8)
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }
}
