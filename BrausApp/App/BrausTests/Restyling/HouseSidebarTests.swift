//
//  HouseSidebarTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import AppKit
import Testing
@testable import Braus

@Suite("HouseSidebar")
@MainActor
struct HouseSidebarTests {

    @Test("Rooms use two columns unless the sidebar is compact")
    func columns() {
        #expect(HouseLayout.columns(sidebarWidth: 280) == 2)
        #expect(HouseLayout.columns(sidebarWidth: 140) == 1)
    }

    @Test("The sidebar mode defaults to rooms")
    func defaultMode() {
        #expect(SidebarMode(preference: nil) == .rooms)
        #expect(SidebarMode(preference: "unknown") == .rooms)
        #expect(SidebarMode(preference: AppPreferences.restylingSidebarModeDefault) == .rooms)
        #expect(SidebarMode(preference: "rows") == .rows)
    }

    @Test("The preference values read the sidebar mode from the defaults")
    func preferenceValuesReadTheMode() throws {
        let name     = "HouseSidebarTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        #expect(AppPreferenceValues(defaults: defaults).restylingSidebarMode == .rooms)

        defaults.set(
            "rows",
            forKey: AppPreferences.restylingSidebarMode
        )
        #expect(AppPreferenceValues(defaults: defaults).restylingSidebarMode == .rows)
    }

    @Test("The selected room says its worker is in chat with you")
    func selectedRoomLabel() throws {
        let worker = try #require(MockHouse.sample.workers.first)
        #expect(HouseRoomCell.spokenLabel(
            for       : worker,
            isSelected: true
        ) == "Delivery, in chat with you")
        #expect(!HouseRoomCell.spokenLabel(
            for       : worker,
            isSelected: false
        ).contains("in chat with you"))
    }

    @Test("The plaque swings down, and only fades in under Reduce Motion")
    func plaqueSwing() {
        defer { RestylingMotion.overrideReducesMotion = nil }
        typealias Plaque = HouseAwayPlaque.PlaqueView

        RestylingMotion.overrideReducesMotion = false
        let swinging = Plaque(brows: .idle)
        swinging.hang()
        let swing = swinging.swingLayer.animation(forKey: Plaque.swingKey)
        #expect(swing is CASpringAnimation)
        #expect((0.6...1.0).contains(swing?.duration ?? 0))

        RestylingMotion.overrideReducesMotion = true
        let still = Plaque(brows: .idle)
        still.hang()
        #expect(still.swingLayer.animation(forKey: Plaque.swingKey) == nil)
        #expect(still.swingLayer.animation(forKey: Plaque.fadeKey) != nil)
    }
}
