import ApplicationServices
import Foundation

final class TextInserter {
    func insert(_ text: String) {
        guard !text.isEmpty else { return }

        let source = CGEventSource(stateID: .combinedSessionState)
        for var chunk in unicodeChunks(from: text) {

            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                continue
            }

            keyDown.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            keyUp.keyboardSetUnicodeString(stringLength: 0, unicodeString: nil)
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }
    }

    private func unicodeChunks(from text: String, maximumUTF16Count: Int = 20) -> [[UniChar]] {
        var chunks: [[UniChar]] = []
        var current: [UniChar] = []

        for character in text {
            let units = Array(String(character).utf16)
            if !current.isEmpty && current.count + units.count > maximumUTF16Count {
                chunks.append(current)
                current = []
            }
            current.append(contentsOf: units)
        }

        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }
}
