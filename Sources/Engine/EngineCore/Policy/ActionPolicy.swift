//
//  ActionPolicy.swift
//  Braus
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import Foundation

/// ActionPolicy is the safety rule a model cannot argue with: a target whose label reads as
/// destructive or irreversible is refused unless the person opted in. Over-matching is the safe
/// direction, so the terms are stems and the match is a substring, in every language a driven app
/// has spoken so far. An English-only list once let "Elimina", "Invia" and "Esci" through.
public enum ActionPolicy {

    static let destructiveTerms: [String] = [
        // English
        "delete", "remove", "trash", "discard", "erase", "reset", "format", "uninstall", "purge", "wipe",
        "destroy", "overwrite", "replace all", "quit", "sign out", "log out", "logout", "deactivate",
        "revoke", "send", "publish", "submit", "buy", "purchase", "pay", "confirm order",
        // Italian, as stems
        "elimin", "cancell", "rimuov", "cestin", "ripristin", "azzera", "svuot", "sovrascriv",
        "esci", "disconnett", "invia", "pubblic", "acquist", "compra", "paga",
    ]

    /// True when the label names something destructive or irreversible. Native audio send selectors
    /// in Pro Tools open routing controls; the same words elsewhere keep the conservative rule.
    public static func isDestructive(
        label    : String?,
        bundleID : String? = nil,
        role     : String? = nil,
        container: String? = nil
    ) -> Bool {
        guard let lowered = label?.lowercased() else { return false }
        if isAudioSendSelector(label: lowered, bundleID: bundleID, role: role, container: container) {
            return false
        }
        return destructiveTerms.contains { lowered.contains($0) }
    }

    /// Checks a menu choice using the native control that opened it. Pro Tools' exact "no send"
    /// choice clears an audio route; without that selector evidence it keeps the general rule.
    public static func isDestructiveMenuItem(
        _ item   : String,
        openedBy : String,
        bundleID : String?,
        role     : String?,
        container: String?
    ) -> Bool {
        if item.lowercased() == "no send",
           isAudioSendSelector(label: openedBy, bundleID: bundleID, role: role, container: container) {
            return false
        }
        return isDestructive(label: item)
    }

    private static func isAudioSendSelector(
        label    : String,
        bundleID : String?,
        role     : String?,
        container: String?
    ) -> Bool {
        guard bundleID == "com.avid.ProTools", role == "AXButton",
              let bank = container?.components(separatedBy: " / ").last
        else { return false }
        let words = label.lowercased().split(separator: " ")
        return words.count == 3 && words[0] == "send" && ["selector", "assignment"].contains(words[1])
            && words[2].count == 1
            && (bank == "Sends A-E" && "abcde".contains(words[2])
                || bank == "Sends F-J" && "fghij".contains(words[2]))
    }

    /// True for Command with Q or W, whatever else is held: they quit or close what the agent is
    /// driving, so they are refused even when the person allowed destructive actions.
    public static func closesTheTarget(_ chord: KeyChord) -> Bool {
        guard chord.modifiers.contains(.command), case .character(let character) = chord.key else { return false }
        return ["q", "w"].contains(character.lowercased())
    }

    /// The labels of a control that closes its window without saving anything. Matched whole, after
    /// `normalizedLabel`: "Cancel download", "Close sidebar" and "Cancelled" are other controls.
    static let windowClosingLabels: Set<String> = ["cancel", "close", "annulla", "chiudi"]

    /// The titles of a menu command that closes the window it is pressed for, matched whole.
    static let windowClosingMenuTitles: Set<String> = ["close", "close window", "chiudi", "chiudi finestra"]

    /// Case, the ellipsis and trailing dots do not tell two labels apart: "Save As\u{2026}",
    /// "Save As..." and "save as" are one label.
    public static func normalizedLabel(_ label: String) -> String {
        var text = label.lowercased().replacingOccurrences(of: "\u{2026}", with: "")
            .trimmingCharacters(in: .whitespaces)
        while text.hasSuffix(".") { text.removeLast() }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// True when the label is exactly the name of a control that closes its window.
    public static func isWindowClosingLabel(_ label: String?) -> Bool {
        label.map { windowClosingLabels.contains(normalizedLabel($0)) } ?? false
    }

    /// True when the menu item title is exactly a command that closes the window.
    public static func isWindowClosingMenuTitle(_ title: String) -> Bool {
        windowClosingMenuTitles.contains(normalizedLabel(title))
    }

    /// True when `text` holds a C0 control character other than tab, line feed and carriage return.
    /// Posted as a key's text, U+001B reads as Escape to AppKit and Qt: text never carries a key.
    public static func containsControlCharacter(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value < 0x20 && !["\t", "\n", "\r"].contains($0) }
    }

    /// Why a text holding a control character was not sent.
    public static let controlCharacterRefusal = "The text holds a control character other than a tab or a line "
        + "break, and U+001B reads as Escape: nothing was sent. Use press_key for a key."

    /// Why a key or a press that closes the only window of an application was not sent, in the
    /// seat's own words: what, why, that nothing was sent, and what to use instead.
    public static func windowClosureRefusal(
        _ what       : String,
        window       : String,
        application  : String,
        alternatives : [String]
    ) -> String {
        let name = window.isEmpty ? "its window" : "'\(window)'"
        let controls = alternatives.isEmpty
            ? "a control of the window by name"
            : "one of its controls by name (\(alternatives.joined(separator: ", ")))"
        let sentence = what.prefix(1).uppercased() + what.dropFirst()
        return "\(sentence) would close \(name), the only window of \(application), with nothing else open: "
            + "the application may quit. Nothing was sent. Use \(controls), or close the session."
    }

    /// The roles whose press opens a menu the panel service of a remote file panel owns.
    public static let menuOpeningRoles: Set<String> = ["AXPopUpButton", "AXMenuButton"]

    /// Why a click on such a control in a remote file panel was refused, in the seat's own words:
    /// `RemoteContentActuationRefusal.opensMenu` says the same, and a test holds the two together.
    public static func menuOpeningRefusal(role: String) -> String {
        "That \(role) opens a menu a click here cannot follow, so it was not pressed. "
            + "Use select with this control and the item, or context_menu."
    }

    /// True for Command with Delete, whatever else is held: it moves to the Trash, deletes a message
    /// or empties the Trash in the applications that bind it.
    public static func isDestructive(_ chord: KeyChord) -> Bool {
        chord.modifiers.contains(.command) && chord.key == .delete
    }
}

/// ActionPermissions is what the person, and only the person, has allowed. A model never sets it.
public struct ActionPermissions: Sendable, Equatable, Codable {

    /// Destructive targets are refused by default; the person flips this to let the agent delete or send.
    public var allowsDestructive: Bool

    /// A contextual menu may be opened only on a text field. Set for a Qt application on the seat: a
    /// custom widget there draws its menu under the person's own pointer, outside the seat, where it
    /// cannot be read, moved or closed, and the seat stays suspended until the person closes it. A text
    /// field's menu opens where the click landed, and it is the only way to reach Copy and Paste.
    public var contextMenusOnTextFieldsOnly: Bool

    /// A field's text is selected with a triple click and no key. Set while the seat holds a file
    /// panel the system draws out of process: measured on 30/09/2026 in Photoshop's Save As panel,
    /// Command and Up went to the enclosing folder, the other selecting keys did nothing, and replacing
    /// the name typed into its middle, while a triple click selected all of it.
    public var selectsFieldsByTripleClick: Bool

    /// A click on a popup or a menu button is refused and nothing presses it. Set while the seat
    /// holds a file panel the system draws out of process: pressed, it opens a menu window the panel
    /// service owns, outside the scene, which stays open (05/10/2026); `select` chooses in it.
    public var refusesMenuOpeningClicks: Bool

    /// What closing the target window would do to its application. When it may end it, Escape, a
    /// click on the window's own closing control and a Close menu command are refused unless
    /// `allowsDestructive` is set: measured on 12/10/2026, Escape on the Project Manager of DaVinci
    /// Resolve closes it and Resolve quits.
    public var windowClosure: WindowClosureGuard

    public init(
        allowsDestructive           : Bool = false,
        contextMenusOnTextFieldsOnly: Bool = false,
        selectsFieldsByTripleClick  : Bool = false,
        refusesMenuOpeningClicks    : Bool = false,
        windowClosure               : WindowClosureGuard = WindowClosureGuard()
    ) {
        self.allowsDestructive            = allowsDestructive
        self.contextMenusOnTextFieldsOnly = contextMenusOnTextFieldsOnly
        self.selectsFieldsByTripleClick   = selectsFieldsByTripleClick
        self.refusesMenuOpeningClicks     = refusesMenuOpeningClicks
        self.windowClosure                = windowClosure
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        allowsDestructive            = try container.decode(Bool.self, forKey: .allowsDestructive)
        contextMenusOnTextFieldsOnly = try container.decodeIfPresent(Bool.self, forKey: .contextMenusOnTextFieldsOnly)
            ?? false
        selectsFieldsByTripleClick   = try container.decodeIfPresent(Bool.self, forKey: .selectsFieldsByTripleClick)
            ?? false
        refusesMenuOpeningClicks     = try container.decodeIfPresent(Bool.self, forKey: .refusesMenuOpeningClicks)
            ?? false
        windowClosure                = try container.decodeIfPresent(WindowClosureGuard.self, forKey: .windowClosure)
            ?? WindowClosureGuard()
    }
}
