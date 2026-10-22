//
//  HouseLiveInspectorTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/10/2026.
//

import SwiftUI
import Testing
@testable import Braus

@Suite("HouseLiveInspector")
@MainActor
struct HouseLiveInspectorTests {

    @Test("The live inspector stands on the real sections, the worker's own first after the screen")
    func sections() {
        let form = String(reflecting: HouseLiveInspector.Content.Body.self)
        let sections = [
            "InspectorScreenSection",
            "HouseWorkerSection",
            "InspectorNowSection",
            "InspectorModelSection",
            "InspectorBrowserSection",
            "InspectorTurnSection",
        ]
        var last = form.startIndex
        for section in sections {
            let found = form.range(of: section)
            #expect(found != nil)
            if let found {
                #expect(found.lowerBound >= last)
                last = found.lowerBound
            }
        }
        #expect(form.contains("Form<"))
    }

    @Test("The live inspector gives its sections the house's row padding and section gap")
    func spacing() {
        #expect(HouseLiveInspector.Content.rowPadding == InspectorRowSpacing.vertical)
        #expect(HouseLiveInspector.Content.footerGap == HouseSectionGap.height)
        #expect(HouseLiveInspector.Content.rowPadding > 0)
        #expect(HouseLiveInspector.Content.footerGap > 0)
    }

    @Test("A name is trimmed, a blank one brings the stored name back and an unchanged one commits nothing")
    func name() {
        let edited = HouseWorkerSection.takingName(
            "  Iris Prime ",
            stored: "Iris"
        )
        #expect(edited.shown == "Iris Prime")
        #expect(edited.commit == "Iris Prime")

        let blank = HouseWorkerSection.takingName(
            "   ",
            stored: "Iris"
        )
        #expect(blank.shown == "Iris")
        #expect(blank.commit == nil)

        let same = HouseWorkerSection.takingName(
            "Iris ",
            stored: "Iris"
        )
        #expect(same.shown == "Iris")
        #expect(same.commit == nil)
    }

    @Test("A role is trimmed, can be cleared, and an unchanged one commits nothing")
    func role() {
        let edited = HouseWorkerSection.takingRole(
            " Editor ",
            stored: "Researcher"
        )
        #expect(edited.shown == "Editor")
        #expect(edited.commit == "Editor")

        let cleared = HouseWorkerSection.takingRole(
            "  ",
            stored: "Researcher"
        )
        #expect(cleared.shown == "")
        #expect(cleared.commit == "")

        #expect(HouseWorkerSection.takingRole(
            "Editor",
            stored: "Editor"
        ).commit == nil)
    }
}
