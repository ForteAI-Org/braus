//
//  CanvasSecureFieldTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

import CoreGraphics
import Foundation
import PerceptionCore
import Testing

@Suite
struct CanvasSecureFieldTests {

    @Test(arguments: ["AXTextField", "AXSecureTextField"])
    func secureRoleSurvivesHarvestAndPixelMerge(role: String) throws {
        let frame = CGRect(
            x: 0,
            y: 0,
            width: 400,
            height: 300
        )
        let field = FakeNode(
            role,
            subrole        : "AXSecureTextField",
            descriptionText: "PIN",
            value          : "must never leave",
            frame          : CGRect(
                x: 40,
                y: 50,
                width: 160,
                height: 30
            )
        )
        let root = FakeNode(
            "AXWindow",
            frame: frame
        ).adding(field)
        let native = AccessibilityAugmentation.elements(
            under      : root,
            windowFrame: frame,
            reader     : FakeReader()
        )
        let element = try #require(native.first)
        #expect(element.role == "AXSecureTextField")
        #expect(element.value == nil)
        var pixel = element
        pixel.role = nil
        pixel.kind = .text
        let merged = AccessibilityAugmentation.merge(
            pixels       : [pixel],
            accessibility: native
        )
        #expect(merged.count == 1)
        #expect(merged.first?.role == "AXSecureTextField")
    }

    @Test
    func ordinaryFieldSceneBytesStayIdentical() throws {
        let frame = CGRect(
            x: 0,
            y: 0,
            width: 400,
            height: 300
        )
        let field = FakeNode(
            "AXTextField",
            descriptionText: "Name",
            value          : "Example",
            frame          : CGRect(
                x: 40,
                y: 50,
                width: 160,
                height: 30
            )
        )
        let root = FakeNode(
            "AXWindow",
            frame: frame
        ).adding(field)
        func encoded() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(AccessibilityAugmentation.elements(
                under      : root,
                windowFrame: frame,
                reader     : FakeReader()
            ))
        }
        let before = try encoded()
        field.subrole = ""
        #expect(try encoded() == before)
        field.subrole = "AXSearchField"
        #expect(try encoded() == before)
    }
}
