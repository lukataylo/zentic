import AppKit
import WebKit
import ZenticKit

enum ExtensionShortcuts {
    /// Whether any item in `menu` or its submenus answers to `chord`.
    @MainActor
    static func menu(_ menu: NSMenu?, uses chord: KeyChord) -> Bool {
        guard let menu else { return false }
        return menu.items.contains { item in
            if let submenu = item.submenu { return self.menu(submenu, uses: chord) }
            return !item.keyEquivalent.isEmpty
                && KeyChord(key: item.keyEquivalent, modifiers: .init(item.keyEquivalentModifierMask)) == chord
        }
    }

    /// "⇧⌘Y", in the order the Mac writes modifiers.
    static func text(for chord: KeyChord) -> String {
        var text = ""
        if chord.modifiers.contains(.control) { text += "⌃" }
        if chord.modifiers.contains(.option) { text += "⌥" }
        if chord.modifiers.contains(.shift) { text += "⇧" }
        if chord.modifiers.contains(.command) { text += "⌘" }
        return text + chord.key.uppercased()
    }
}

extension KeyChord.Modifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.command) { insert(.command) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.control) { insert(.control) }
        if flags.contains(.shift) { insert(.shift) }
    }
}

extension WKWebExtension.Command {
    /// The keys the extension assigned, if any.
    var chord: KeyChord? {
        guard let key = activationKey, !key.isEmpty else { return nil }
        return KeyChord(key: key, modifiers: .init(modifierFlags))
    }
}
