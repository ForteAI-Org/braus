//
//  InteractionCommandName.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/10/2026.
//

import Carbon.HIToolbox
import Foundation

/// InteractionCommandName names shortcuts without ever inspecting or translating typing events.
public enum InteractionCommandName {
    @MainActor
    public static func render(_ event: InteractionEvent) -> String? {
        render(event, translate: layoutKey)
    }

    static func render(_ event: InteractionEvent, translate: (UInt16) -> String?) -> String? {
        guard event.kind == .shortcut else { return nil }
        let modifiers = event.modifiers ?? []
        let prefix = (modifiers.contains(.control) ? "⌃" : "")
            + (modifiers.contains(.option) ? "⌥" : "")
            + (modifiers.contains(.shift) ? "⇧" : "")
            + (modifiers.contains(.command) ? "⌘" : "")
        guard let code = event.keyCode else { return prefix + "unknown key" }
        let names: [UInt16: String] = [
            36: "Return", 48: "Tab",
            49: "Space", 51: "Delete", 53: "Escape", 71: "Clear", 76: "Enter", 114: "Help",
            115: "Home", 116: "PageUp", 117: "ForwardDelete", 119: "End", 121: "PageDown",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
            106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
        ]
        if let name = names[code] { return prefix + name }
        if modifiers.contains(.command) || modifiers.contains(.control), let key = translate(code) {
            return prefix + key.uppercased()
        }
        return prefix + "key#\(code)"
    }

    /// Translates only a command's virtual key, with no modifiers and no dead-key state.
    @MainActor
    private static func layoutKey(_ code: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKey: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 8)
        let result = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                    OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKey,
                                    characters.count, &length, &characters)
        guard result == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }
}
