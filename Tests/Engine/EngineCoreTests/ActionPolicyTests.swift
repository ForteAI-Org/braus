//
//  ActionPolicyTests.swift
//  Braus
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

@testable import EngineCore
import Foundation
import Testing

@Suite("Action policy")
struct ActionPolicyTests {

    @Test("destructive labels are caught in English and Italian, safe ones pass")
    func destructive() {
        for label in ["Delete", "Empty Trash", "Send", "Quit Premiere", "Elimina", "Invia messaggio", "Esci", "Svuota"] {
            #expect(ActionPolicy.isDestructive(label: label), Comment(rawValue: label))
        }
        for label in ["Export", "Save", "Mute Track", "Audio 4", "48000", "OK"] {
            #expect(!ActionPolicy.isDestructive(label: label), Comment(rawValue: label))
        }
        #expect(!ActionPolicy.isDestructive(label: nil))
    }

    @Test("activation is skipped in front or while a pop-up is open")
    func activation() {
        #expect(ActivationPolicy.needsActivation(target: 5, frontmost: 7, isPopupOpen: false))
        #expect(!ActivationPolicy.needsActivation(target: 5, frontmost: 5, isPopupOpen: false))
        #expect(!ActivationPolicy.needsActivation(target: 5, frontmost: 7, isPopupOpen: true))
        #expect(ActivationPolicy.needsActivation(target: 5, frontmost: nil, isPopupOpen: false))
    }

    @Test("permissions encoded before a rule existed decode with that rule off")
    func permissionsDecodeOlderEncodings() throws {
        let older = try JSONDecoder().decode(ActionPermissions.self, from: Data(#"{"allowsDestructive":true}"#.utf8))
        #expect(older == ActionPermissions(allowsDestructive: true))
        let rules = ActionPermissions(contextMenusOnTextFieldsOnly: true, selectsFieldsByTripleClick: true)
        #expect(try JSONDecoder().decode(ActionPermissions.self, from: JSONEncoder().encode(rules)) == rules)
    }

    @Test("a window closing label is matched whole, never by a substring")
    func windowClosingLabels() {
        for label in ["Cancel", " cancel ", "Close", "Annulla", "Chiudi", "Cancel...", "Cancel\u{2026}"] {
            #expect(ActionPolicy.isWindowClosingLabel(label), Comment(rawValue: label))
        }
        for label in ["Cancel download", "Close sidebar", "Cancelled", "Annulla ordine", "Disclose", "", "Open"] {
            #expect(!ActionPolicy.isWindowClosingLabel(label), Comment(rawValue: label))
        }
        #expect(!ActionPolicy.isWindowClosingLabel(nil))
    }

    @Test("a Close menu command is matched whole, in English and Italian")
    func windowClosingMenuTitles() {
        for title in ["Close", "Close Window", "close window", "Chiudi", "Chiudi finestra", "Close\u{2026}"] {
            #expect(ActionPolicy.isWindowClosingMenuTitle(title), Comment(rawValue: title))
        }
        for title in ["Close All", "Close Tab", "Close Project", "Chiudi tutto", "Cancel", "New Window"] {
            #expect(!ActionPolicy.isWindowClosingMenuTitle(title), Comment(rawValue: title))
        }
    }

    @Test("a C0 control character other than a tab or a line break is a key, not text")
    func controlCharacters() {
        for text in ["\u{1B}", "a\u{1B}b", "\u{0}", "\u{7}", "\u{8}", "\u{1F}"] {
            #expect(ActionPolicy.containsControlCharacter(text), Comment(rawValue: text.debugDescription))
        }
        for text in ["Braus", "a\tb", "one\ntwo", "one\r\ntwo", "\u{7F}", "é 🧪", " "] {
            #expect(!ActionPolicy.containsControlCharacter(text), Comment(rawValue: text.debugDescription))
        }
    }

    @Test("verbs keep the tool vocabulary")
    func verbs() {
        #expect(ActionVerb(rawValue: "double_click") == .doubleClick)
        #expect(ActionVerb.setToggle.rawValue == "set_toggle")
        #expect(ActionVerb.click.performed == "clicked")
    }
}
