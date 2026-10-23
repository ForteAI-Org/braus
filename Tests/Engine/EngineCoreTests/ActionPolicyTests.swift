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

    @Test("a plural noun Sends is a view, the verb Send stays destructive")
    func sendsNounIsNotTheVerb() {
        for label in ["Sends A-E", "Sends F-J", "Show Sends"] {
            #expect(!ActionPolicy.isDestructive(label: label, role: "AXMenuItem"), Comment(rawValue: label))
            #expect(!ActionPolicy.isDestructiveMenuItem(
                label, openedBy: "Mix Window Views", bundleID: "com.avid.ProTools", role: "AXMenuItem", container: nil
            ), Comment(rawValue: label))
        }
        for label in ["Send", "Send Message", "Sending", "Invia messaggio"] {
            #expect(ActionPolicy.isDestructive(label: label, role: "AXButton"), Comment(rawValue: label))
        }
    }

    @Test("a format popup numbered by its row is still a selector, a real format action is not")
    func numberedFormatSelector() {
        for label in ["Track format", "Track format #2", "Track Format #3", "Formato traccia #2"] {
            #expect(!ActionPolicy.isDestructiveSelectionControl(label: label, role: "AXPopUpButton"), Comment(rawValue: label))
        }
        for (label, role) in [
            ("Format Disk", "AXPopUpButton"), ("Format Disk #2", "AXPopUpButton"), ("Format...", "AXMenuItem"),
            ("Track format #2", "AXButton"), ("Delete #2", "AXPopUpButton"), ("Format #2 Disk", "AXPopUpButton"),
        ] {
            #expect(ActionPolicy.isDestructiveSelectionControl(label: label, role: role), Comment(rawValue: label))
        }
        #expect(!ActionPolicy.isDestructiveSelectionControl(label: "Track name #2", role: "AXPopUpButton"))
    }

    @Test("no send clears an audio route only when its native selector supplies the context")
    func audioSendMenu() {
        for (item, bundle, container, destructive) in [
            ("no send", "com.avid.ProTools", "Kick / Sends A-E", false),
            ("No Send", "com.avid.ProTools", "Kick / Sends A-E", false),
            ("no send", "com.example.mail", "Kick / Sends A-E", true),
            ("no send", "com.avid.ProTools", "Message", true),
            ("Send message", "com.avid.ProTools", "Kick / Sends A-E", true),
            ("Delete", "com.avid.ProTools", "Kick / Sends A-E", true),
        ] {
            #expect(ActionPolicy.isDestructiveMenuItem(
                item, openedBy: "Send selector A", bundleID: bundle, role: "AXButton", container: container
            ) == destructive)
        }
        #expect(ActionPolicy.isDestructive(label: "no send"))
    }

    @Test("a radio button or a tab named exactly Format selects an inspector pane: not destructive (Numbers, B2 trial)")
    func paneSelector() {
        #expect(!ActionPolicy.isDestructive(label: "Format", role: "AXRadioButton"))
        #expect(!ActionPolicy.isDestructive(label: "format", role: "AXTab"))
        #expect(!ActionPolicy.isDestructive(label: "Format\u{2026}", role: "AXRadioButton"), "the ellipsis does not tell labels apart")
    }

    @Test("everything else that reads as destructive stays refused, Format included",
          arguments: [("Format", "AXButton"), ("Format", nil), ("Format\u{2026}", "AXMenuItem"), ("Format", "AXMenuButton"),
                      ("Format Disk", "AXRadioButton"), ("Format and Erase", "AXTab"), ("Delete", "AXRadioButton"),
                      ("Erase", "AXTab"), ("Formatta disco", "AXRadioButton"), ("Format", "AXPopUpButton")] as [(String, String?)])
    func destructiveStays(label: String, role: String?) {
        #expect(ActionPolicy.isDestructive(label: label, role: role), Comment(rawValue: "\(label) \(role ?? "no role")"))
        #expect(ActionPolicy.isDestructive(label: "Format"), "the label alone keeps every match")
    }

    @Test("the two context rules compose: each exception needs its own context and lends none to the other")
    func contextRulesCompose() {
        let bank = "Kick / Sends A-E"
        // The audio send selector is recognized only as Pro Tools' button in its bank.
        #expect(!ActionPolicy.isDestructive(label: "Send selector A", bundleID: "com.avid.ProTools",
                                            role: "AXButton", container: bank))
        #expect(ActionPolicy.isDestructive(label: "Send selector A", bundleID: "com.avid.ProTools",
                                           role: "AXRadioButton", container: bank))
        #expect(ActionPolicy.isDestructive(label: "Send selector A", role: "AXButton", container: bank))
        // A pane selector stays a pane selector in any application, and a destructive pane name in Pro Tools' bank
        // gains nothing from the bank.
        #expect(!ActionPolicy.isDestructive(label: "Format", bundleID: "com.avid.ProTools",
                                            role: "AXRadioButton", container: bank))
        #expect(ActionPolicy.isDestructive(label: "Delete", bundleID: "com.avid.ProTools",
                                           role: "AXButton", container: bank))
        // A menu item opened by a pane selector keeps the label's rule.
        #expect(ActionPolicy.isDestructiveMenuItem("no send", openedBy: "Format", bundleID: "com.avid.ProTools",
                                                   role: "AXRadioButton", container: bank))
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
