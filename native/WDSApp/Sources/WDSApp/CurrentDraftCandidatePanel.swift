import AppKit
import CoreGraphics

/// A small, non-activating review surface anchored near the candidate text.
/// It never edits the target directly; the app delegate owns every safety check
/// and performs the edit only after `onApprove` fires.
final class CurrentDraftCandidatePanel: NSObject {
    private var panel: NSPanel?
    private var onApprove: (() -> Void)?
    private var onKeep: (() -> Void)?
    private var onReplace: (() -> Void)?

    var isVisible: Bool { panel?.isVisible == true }

    func present(
        phrase: String,
        targetBounds: CGRect,
        keyboardShortcutsAvailable: Bool,
        replacement: String? = nil,
        onApprove: @escaping () -> Void,
        onKeep: @escaping () -> Void,
        onReplace: (() -> Void)? = nil
    ) {
        dismiss()
        self.onApprove = onApprove
        self.onKeep = onKeep
        self.onReplace = onReplace

        let compactPhrase = phrase
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        // A replacement is offered only when the user registered one for this phrase.
        let hasReplacement = replacement != nil && onReplace != nil
        let labelText = hasReplacement
            ? "WDS  \u{201c}\(compactPhrase)\u{201d} 줄일까요?"
            : "WDS  \u{201c}\(compactPhrase)\u{201d} 덜어낼까요?"
        let measuredLabelWidth = ceil((labelText as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)]
        ).width)

        let keepWidth: CGFloat = keyboardShortcutsAvailable ? 94 : 56
        let approveWidth: CGFloat = keyboardShortcutsAvailable ? 82 : 66
        let replaceWidth: CGFloat = 60
        let buttonGap: CGFloat = 6
        let rightMargin: CGFloat = 14
        var groupWidth = keepWidth + approveWidth + buttonGap
        if hasReplacement { groupWidth += replaceWidth + buttonGap }
        // Reserve the button group plus the right margin, the label's 15px left
        // inset, and a gap so the label frame ends before the leftmost button.
        let labelInset: CGFloat = 15
        let labelGap: CGFloat = 8
        let controlsWidth = groupWidth + rightMargin + labelInset + labelGap
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
        label.toolTip = hasReplacement
            ? "WDS가 현재 초안에서 찾은 등록 문구 후보"
            : "WDS가 현재 초안에서 찾은 로컬 삭제 후보"
        background.addSubview(label)

        // Lay the buttons out right to left: 날리기 (rightmost), optional 치환, 유지.
        var trailingX = width - rightMargin

        let approveButton = NSButton(
            title: keyboardShortcutsAvailable ? "날리기  ⌃⌘⌫" : "날리기",
            target: self,
            action: #selector(approvePressed)
        )
        approveButton.bezelStyle = .rounded
        approveButton.controlSize = .small
        approveButton.keyEquivalent = ""
        approveButton.frame = NSRect(x: trailingX - approveWidth, y: 13, width: approveWidth, height: 26)
        approveButton.toolTip = keyboardShortcutsAvailable
            ? "⌃⌘⌫ • 초안과 범위를 다시 확인한 뒤 이 구간만 삭제합니다"
            : "초안과 범위를 다시 확인한 뒤 이 구간만 삭제합니다"
        approveButton.setAccessibilityLabel("후보 날리기")
        background.addSubview(approveButton)
        trailingX -= approveWidth + buttonGap

        if hasReplacement {
            let replaceButton = NSButton(title: "치환", target: self, action: #selector(replacePressed))
            replaceButton.bezelStyle = .rounded
            replaceButton.controlSize = .small
            replaceButton.frame = NSRect(x: trailingX - replaceWidth, y: 13, width: replaceWidth, height: 26)
            replaceButton.toolTip = replacement.map { "\u{201c}\($0)\u{201d}(으)로 바꿉니다 • 초안과 범위를 다시 확인한 뒤 이 구간만 치환합니다" }
            replaceButton.setAccessibilityLabel("후보 치환")
            background.addSubview(replaceButton)
            trailingX -= replaceWidth + buttonGap
        }

        let keepButton = NSButton(
            title: keyboardShortcutsAvailable ? "유지  ⌃⌘K" : "유지",
            target: self,
            action: #selector(keepPressed)
        )
        keepButton.bezelStyle = .rounded
        keepButton.controlSize = .small
        keepButton.frame = NSRect(x: trailingX - keepWidth, y: 13, width: keepWidth, height: 26)
        keepButton.toolTip = keyboardShortcutsAvailable
            ? "⌃⌘K • 이 입력창에서는 같은 후보를 다시 띄우지 않습니다"
            : "이 입력창에서는 같은 후보를 다시 띄우지 않습니다"
        keepButton.setAccessibilityLabel("후보 유지")
        background.addSubview(keepButton)

        panel.contentView = background
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        onApprove = nil
        onKeep = nil
        onReplace = nil
    }

    @objc private func approvePressed() {
        let completion = onApprove
        completion?()
    }

    @objc private func keepPressed() {
        let completion = onKeep
        completion?()
    }

    @objc private func replacePressed() {
        let completion = onReplace
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
