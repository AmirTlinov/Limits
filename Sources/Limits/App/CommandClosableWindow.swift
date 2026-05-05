import AppKit

final class CommandClosableWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isCloseWindowShortcut(event) {
            close()
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if isCloseWindowShortcut(event) {
            close()
            return
        }

        super.keyDown(with: event)
    }

    private func isCloseWindowShortcut(_ event: NSEvent) -> Bool {
        let shortcutFlags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let isCloseWindowKey = event.charactersIgnoringModifiers?.lowercased() == "w" || event.keyCode == 13
        return shortcutFlags == .command && isCloseWindowKey
    }
}
