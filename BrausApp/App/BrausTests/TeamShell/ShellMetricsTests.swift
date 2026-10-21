//
//  ShellMetricsTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Testing
@testable import Braus

@Suite("The team window's widths")
struct ShellMetricsTests {

    @Test("Each column starts inside its own range, and the ranges are the spec's tokens")
    func theColumnTokensAreConsistent() {
        for column in [ShellMetrics.sidebar, ShellMetrics.inspector] {
            #expect(column.minimum <= column.ideal && column.ideal <= column.maximum)
        }
        #expect(ShellMetrics.sidebar   == ColumnWidth(ideal: 280, minimum: 200, maximum: 340))
        #expect(ShellMetrics.inspector == ColumnWidth(ideal: 360, minimum: 320, maximum: 440))
        #expect(ShellMetrics.compactSidebar == 140)
        #expect(ShellMetrics.compactSidebar < ShellMetrics.sidebar.minimum)
    }

    @Test("A sidebar narrower than the full rows read shows the compact tiles")
    func aNarrowSidebarShowsTiles() {
        #expect(ShellMetrics.showsCompactTiles(sidebarWidth: ShellMetrics.compactSidebar))
        #expect(ShellMetrics.showsCompactTiles(sidebarWidth: 199))
        #expect(!ShellMetrics.showsCompactTiles(sidebarWidth: 200))
        #expect(!ShellMetrics.showsCompactTiles(sidebarWidth: ShellMetrics.sidebar.ideal))
    }
}
