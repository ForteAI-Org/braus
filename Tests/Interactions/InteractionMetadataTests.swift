//
//  InteractionMetadataTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/10/2026.
//

import CoreGraphics
import Foundation
@testable import InteractionListener
@testable import InteractionObservation
import Testing

@Suite
struct InteractionMetadataTests {
    @Test func dialogButtonsAreNamedByTheirWindowNotTheirCaption() {
        for (key, part) in [("AXDefaultButton", InteractionElementMetadata.WindowButton.default), ("AXCancelButton", .cancel)] {
            let button = InteractionElementMetadata.read(isReservedLabel: { _ in false }, isWindowButton: { $0 == key }) { key in
                ["AXRole": "AXButton"][key]
            }
            #expect(button.windowButton == part)
            #expect(button.label == nil)
        }
        let check = InteractionElementMetadata.read(isReservedLabel: { _ in false }, isWindowButton: { _ in true }) { key in
            ["AXRole": "AXCheckBox", "AXTitle": "Annulla"][key]
        }
        #expect(check.windowButton == nil)
    }

    @Test func metadataNeverRequestsValuesAndWithholdsProtectedLabels() {
        for secure in [false, true] {
            var requested: [String] = []
            let metadata = InteractionElementMetadata.read(isReservedLabel: { $0 == "API key" }) { key in
                requested.append(key)
                return ["AXRole": "AXTextField", "AXSubrole": secure ? "AXSecureTextField" : "",
                        "AXTitle": "API key", "AXValue": "typed-secret"] [key]
            }
            #expect(metadata.isProtected)
            #expect(metadata.label == nil)
            #expect(metadata.role == "AXTextField")
            #expect(!requested.contains("AXValue"))
            if secure { #expect(!requested.contains("AXTitle")) }
        }
        let ordinary = InteractionElementMetadata.read(isReservedLabel: { _ in false }) { key in
            ["AXRole": "AXTextField", "AXSubrole": "AXUnknown", "AXDescription": "Track name", "AXValue": "typed-secret"][key]
        }
        #expect(ordinary.label == "Track name")
        #expect(!ordinary.isProtected)
        let help = InteractionElementMetadata.read(isReservedLabel: { _ in false }) { key in
            ["AXRole": "AXButton", "AXDescription": "", "AXHelp": "Add track"][key]
        }
        #expect(help.label == "Add track")

    }

    @Test func aMissingSubroleDoesNotProtectAnOrdinaryField() {
        var requested: [String] = []
        let result = InteractionElementMetadata.read(isReservedLabel: { _ in false }) { key in
            requested.append(key)
            return ["AXRole": "AXTextField", "AXTitle": "Private label"][key]
        }
        #expect(!result.isProtected)
        #expect(result.role == "AXTextField")
        #expect(result.label == "Private label")
        #expect(!requested.contains("AXValue"))
    }

    @Test func aMissingRoleIsUnknownAndNotProtected() {
        let result = InteractionElementMetadata.read(isReservedLabel: { _ in false }) { _ in nil }
        #expect(result.role == nil)
        #expect(result.label == nil)
        #expect(!result.isProtected)
    }

    @Test func titleElementsNamePlainTextAreasWithoutReadingFieldValues() {
        for labelKey in ["AXTitle", "AXDescription", "AXValue"] {
            var requested: [String] = []
            let result = InteractionElementMetadata.read(
                isReservedLabel: { _ in false },
                titleElementAttribute: { key in
                    requested.append("label.\(key)")
                    return ["AXRole": "AXStaticText", labelKey: "Track name"][key]
                },
                attribute: { key in
                    requested.append("field.\(key)")
                    return ["AXRole": "AXTextArea", "AXValue": "typed-secret"][key]
                }
            )
            #expect(result.label == "Track name")
            #expect(!result.isProtected)
            #expect(!requested.contains("field.AXValue"))
        }
    }

    @Test func onlyStaticTitleElementsSupplyValuesAndPlaceholderIsAFallback() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox", "AXSecureTextField", "AXUnknown", ""] {
            var requested: [String] = []
            let result = InteractionElementMetadata.read(
                isReservedLabel: { _ in false },
                titleElementAttribute: { key in
                    requested.append("label.\(key)")
                    return ["AXRole": role, "AXValue": "typed-secret"][key]
                },
                attribute: { key in
                    requested.append("field.\(key)")
                    return ["AXRole": "AXTextArea", "AXPlaceholderValue": "Track name", "AXValue": "typed-secret"][key]
                }
            )
            #expect(result.label == "Track name")
            #expect(!result.isProtected)
            #expect(!requested.contains("field.AXValue"))
            #expect(!requested.contains("label.AXValue"))
        }
    }

    @Test func secureRolesAndReservedFallbackLabelsRemainProtected() {
        let secure = InteractionElementMetadata.read(isReservedLabel: { _ in false }) { key in
            #expect(key == "AXRole" || key == "AXSubrole")
            return key == "AXRole" ? "AXSecureTextField" : nil
        }
        #expect(secure.isProtected && secure.label == nil)
        for secretKey in ["AXTitle", "AXDescription", "AXHelp", "AXPlaceholderValue", "label.AXTitle",
                          "label.AXDescription", "label.AXValue"] {
            let result = InteractionElementMetadata.read(
                isReservedLabel: { $0 == "Password" },
                titleElementAttribute: { key in
                    if key == "AXRole" { return "AXStaticText" }
                    return "label.\(key)" == secretKey ? "Password" : nil
                },
                attribute: { key in
                    #expect(key != "AXValue")
                    if key == "AXRole" { return "AXTextArea" }
                    return key == secretKey ? "Password" : nil
                }
            )
            #expect(result.isProtected)
            #expect(result.label == nil)
        }
    }

    @Test func onlyCommandOrControlShortcutsTranslateLayoutKeys() {
        func event(_ kind: InteractionEvent.Kind, code: UInt16, modifiers: InteractionEvent.Modifiers) -> InteractionEvent {
            .init(kind: kind, timestamp: Date(), startedAt: 0, endedAt: 1,
                  precedingRevision: 0, revision: 1, point: .zero, window: nil, processID: 42,
                  keyCode: code, modifiers: modifiers)
        }
        var translated: [UInt16] = []
        let translate = { (code: UInt16) -> String? in translated.append(code); return "è" }
        #expect(InteractionCommandName.render(event(.shortcut, code: 41, modifiers: .command), translate: translate) == "⌘È")
        #expect(InteractionCommandName.render(event(.shortcut, code: 41, modifiers: .control), translate: translate) == "⌃È")
        #expect(InteractionCommandName.render(event(.shortcut, code: 36, modifiers: []), translate: translate) == "Return")
        #expect(InteractionCommandName.render(event(.typing, code: 41, modifiers: .command), translate: translate) == nil)
        #expect(InteractionCommandName.render(event(.shortcut, code: 41, modifiers: .option), translate: translate) == "⌥key#41")
        #expect(translated == [41, 41])
    }
}
