import ApplicationServices
import AppKit
import CoreGraphics
import Darwin
import Foundation
import WDSAppCore
import WDSWhackCore

/// Phrase-dictionary menu actions.
extension AppDelegate {
    @objc func addPhraseEntry() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "말버릇 추가"
        alert.informativeText = "전송 전에 초안에서 찾을 문구를 입력하세요. 바꿀 말을 적으면 치환, 비우면 삭제 후보가 됩니다."
        alert.addButton(withTitle: "추가")
        alert.addButton(withTitle: "취소")

        let phraseField = NSTextField(frame: NSRect(x: 0, y: 58, width: 320, height: 24))
        phraseField.placeholderString = "찾을 문구 (예: 혹시 가능하시다면)"
        let replacementField = NSTextField(frame: NSRect(x: 0, y: 28, width: 320, height: 24))
        replacementField.placeholderString = "바꿀 말 (선택 · 비우면 삭제)"
        let autoApplyCheckbox = NSButton(
            checkboxWithTitle: "물어보지 않고 자동 정리 (검증은 동일하게 수행)",
            target: nil,
            action: nil
        )
        autoApplyCheckbox.frame = NSRect(x: 0, y: 0, width: 320, height: 22)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 86))
        container.addSubview(phraseField)
        container.addSubview(replacementField)
        container.addSubview(autoApplyCheckbox)
        alert.accessoryView = container
        alert.window.initialFirstResponder = phraseField

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            let entry = try DictionaryEntry(
                id: UUID().uuidString,
                rawPhrase: phraseField.stringValue,
                replacement: replacementField.stringValue,
                autoApply: autoApplyCheckbox.state == .on
            )
            if dictionaryStore.add(entry) {
                setStatus(entry.autoApply
                    ? "말버릇 추가(자동): \u{201c}\(entry.phrase)\u{201d}"
                    : "말버릇 추가: \u{201c}\(entry.phrase)\u{201d}")
            } else {
                setStatus("이미 등록된 문구입니다")
            }
        } catch DictionaryEntryError.emptyPhrase {
            setStatus("문구가 비어 있어 추가하지 않았습니다")
        } catch DictionaryEntryError.noOpReplacement {
            setStatus("찾을 문구와 바꿀 말이 같아 추가하지 않았습니다")
        } catch DictionaryEntryError.recursiveReplacement {
            setStatus("바꿀 말이 찾을 문구를 포함해 추가하지 않았습니다 (무한 반복 방지)")
        } catch {
            setStatus("문구를 추가하지 못했습니다")
        }
    }

    @objc func togglePhraseEntry(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        dictionaryStore.toggleActive(id: id)
    }

    @objc func toggleAutoApplyEntry(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        dictionaryStore.toggleAutoApply(id: id)
    }

    @objc func removePhraseEntry(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        dictionaryStore.remove(id: id)
    }
}
