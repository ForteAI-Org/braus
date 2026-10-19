//
//  WebSecureFieldTests.swift
//  Braus
//

import CoreGraphics
import Foundation
import JavaScriptCore
import PerceptionCore
import Testing
import WebDriver
@testable import WebDriving

/// Which inputs are secure fields, decided the same way in Swift (the scene) and in JavaScript (the
/// read-back scripts, run here in JavaScriptCore on stand-in elements), and what a secure field
/// leaves in a scene: no value, whatever the tree says it holds.
@Suite("Web secure fields")
struct WebSecureFieldTests {

    /// Attributes of an input, and whether it is a secure field.
    static let cases: [([String: String], Bool)] = [
        (["type": "password"], true),
        (["type": " PassWord "], true),
        (["autocomplete": "cc-number"], true),
        (["autocomplete": "billing cc-csc"], true),
        (["autocomplete": "CC-EXP"], true),
        (["autocomplete": "cc-exp-month"], true),
        (["autocomplete": "cc-exp-year"], true),
        (["autocomplete": "one-time-code"], true),
        (["autocomplete": "current-password webauthn"], true),
        (["autocomplete": "new-password"], true),
        (["name": "cardnumber"], true),
        (["name": "card_number"], true),
        (["name": "creditCardNumber"], true),
        (["id": "CARD-NUMBER"], true),
        (["name": "cc-num"], true),
        (["name": "cvv"], true),
        (["name": "CVV2"], true),
        (["id": "card_cvc"], true),
        (["name": "securityCode"], true),
        (["name": "otp-3"], true),
        (["name": "one_time_code"], true),
        (["id": "oneTimeCode"], true),
        (["name": "email_verification_code"], true),
        (["name": "sms_code"], true),
        (["name": "2fa_code"], true),
        (["name": "newPassword"], true),
        (["name": "user_pwd", "type": "text"], true),
        (["name": "exp_month"], true),
        (["id": "expYear"], true),
        (["name": "cc-exp"], true),
        (["name": "card_expiry", "type": "tel"], true),
        // Ordinary fields, numeric ones included.
        (["name": "quantity", "type": "number"], false),
        (["name": "zipcode"], false),
        (["name": "zip_code"], false),
        (["name": "postal_code", "autocomplete": "postal-code"], false),
        (["name": "phone_number", "type": "tel"], false),
        (["id": "phoneNumber"], false),
        (["name": "order_no"], false),
        (["name": "pincode"], false),
        (["name": "pin_code"], false),
        (["name": "promo_code"], false),
        (["name": "card_holder", "autocomplete": "cc-name"], false),
        (["name": "expiration_date"], false),
        (["name": "cc"], false),
        (["name": "hotpot"], false),
        (["name": "passwordless_email"], false),
        (["name": "account_number"], false),
        (["autocomplete": "off"], false),
        ([:], false),
        // Only a text-like input counts by its autocomplete or its name.
        (["type": "checkbox", "name": "otp"], false),
        (["type": "hidden", "name": "cvv"], false),
        (["type": "submit", "autocomplete": "cc-number"], false),
    ]

    @Test("The rule in Swift and in the page's JavaScript say the same of every case")
    func classification() throws {
        let context = try #require(JSContext())
        let secure  = try #require(context.evaluateScript(WebSecureFields.function))
        for (attributes, expected) in Self.cases {
            #expect(WebSecureFields.isSecure(tag: "INPUT", attributes: attributes) == expected, "\(attributes)")
            let element = try #require(context.evaluateScript("""
                ((attributes) => ({ tagName: 'INPUT', getAttribute: n => n in attributes ? attributes[n] : null }))
                """)).call(withArguments: [attributes])
            #expect(secure.call(withArguments: [element as Any]).toBool() == expected, "\(attributes)")
        }
        #expect(!WebSecureFields.isSecure(tag: "TEXTAREA", attributes: ["name": "password"]))
        #expect(WebSecureFields.isSecure(tag: "input", attributes: ["type": "password"]))
    }

    @Test("A name is read as words, the way the page's script reads it")
    func words() {
        #expect(WebSecureFields.words("creditCardNumber") == ["credit", "card", "number"])
        #expect(WebSecureFields.words("CCNumber_2x") == ["ccnumber", "2x"])
        #expect(WebSecureFields.words("otp-1") == ["otp", "1"])
        #expect(WebSecureFields.words("a1B2C") == ["a1", "b2", "c"])
        #expect(WebSecureFields.words("") == [])
    }

    @Test("The snapshot names the secure inputs of every document by their attributes")
    func snapshot() throws {
        let snapshot: JSONValue = [
            "strings": ["https://example.com/", "Pay", "INPUT", "type", "PASSWORD", "name", "card_number",
                        "quantity", "DIV", "autocomplete", "one-time-code", "checkbox", "otp", "Type"],
            "documents": [
                [
                    "documentURL": 0, "title": 1, "scrollOffsetX": 0, "scrollOffsetY": 0,
                    "nodes": [
                        "nodeName"     : [2, 2, 2, 8, 2],
                        "backendNodeId": [10, 11, 12, 13, 14],
                        "attributes"   : [[13, 4], [5, 6], [5, 7], [5, 6], [3, 11, 5, 12]],
                    ],
                    "layout": ["nodeIndex": [], "bounds": []],
                ],
                [
                    "nodes": ["nodeName": [2], "backendNodeId": [20], "attributes": [[9, 10]]],
                ],
            ],
        ]
        let metrics: JSONValue = ["cssLayoutViewport": ["clientWidth": 800, "clientHeight": 600]]
        let layout = try WebLayout(snapshot: snapshot, metrics: metrics)
        // A password by its type, a card number by its name, and a one-time code in a frame. Not the
        // quantity, the DIV named like a card or the checkbox named otp.
        #expect(layout.secureFieldIDs == [10, 11, 20])
    }

    @Test("A secure field is a secure text field with no value, whatever role and value the tree gives it",
          arguments: ["textbox", "spinbutton", "searchbox", "combobox", "generic"])
    func scene(role: String) throws {
        let nodes = [
            WebAXNode(id: "1", childIDs: ["2", "3"], role: "RootWebArea", backendNodeID: 1),
            WebAXNode(id: "2", parentID: "1", role: role, name: "Card", value: "4111111111111111", backendNodeID: 2),
            WebAXNode(id: "3", parentID: "1", role: "spinbutton", name: "Quantity", value: "3", backendNodeID: 3),
        ]
        let layout = WebLayout(boxes: [2: CGRect(x: 10, y: 10, width: 200, height: 20),
                                       3: CGRect(x: 10, y: 40, width: 200, height: 20)],
                               viewport: CGSize(width: 500, height: 500), url: "https://shop.example.com",
                               secureFieldIDs: [2])
        let scene = WebSceneBuilder.scene(nodes: nodes, layout: layout)
        let card  = try #require(scene.elements.first { $0.label == "Card" })
        #expect(card.role == "AXSecureTextField" && card.value == nil && card.kind == .control)
        #expect(!scene.elements.contains { ($0.value ?? "").contains("4111") || $0.label.contains("4111") })
        #expect(scene.elements.first { $0.label == "Quantity" }?.value == "3")
    }

    @Test("The read-back scripts read no secure field: not the focused one, not among the controls' values")
    func readBack() throws {
        let context = try #require(JSContext())
        context.evaluateScript("""
            const field = (tagName, attributes, value) => ({
              tagName, value, type: (attributes.type || 'text').toLowerCase(), isContentEditable: false,
              getAttribute: n => n in attributes ? attributes[n] : null,
            });
            const card = field('INPUT', { name: 'cardNumber' }, '4111111111111111');
            const code = field('INPUT', { autocomplete: 'one-time-code' }, '654321');
            const key  = field('INPUT', { type: 'password' }, 'hunter2');
            const zip  = field('INPUT', { name: 'zip_code' }, '10115');
            var document = { activeElement: card, querySelectorAll: () => [card, code, key, zip] };
            """)
        #expect(context.evaluateScript(WebControls.focusedFieldScript).isNull)
        context.evaluateScript("document.activeElement = zip")
        #expect(context.evaluateScript(WebControls.focusedFieldScript).toString() == "10115")
        #expect(context.evaluateScript(WebControls.controlValuesScript).toArray() as? [String] == ["10115"])
    }
}
