//
//  HouseSidebarTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import Foundation
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
}
