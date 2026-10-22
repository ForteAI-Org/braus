//
//  HouseWindowLayoutTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import Testing
@testable import Braus

@Suite("The house window reserves conversation space with stable column widths")
struct HouseWindowLayoutTests {

    private typealias Division = ShellMetrics.Division

    private static let full = Division(
        isInspectorShown: true,
        isSidebarCompact: false
    )

    private static let compact = Division(
        isInspectorShown: true,
        isSidebarCompact: true
    )

    private static let narrow = Division(
        isInspectorShown: false,
        isSidebarCompact: true
    )

    @Test("Each division leaves the conversation reserve beside the columns' ideal widths")
    func everyDivisionReservesTheConversationAtIdealWidths() {
        let previousDivisions: [Division?] = [nil, .withoutInspector, Self.full, Self.compact, Self.narrow]
        for previous in previousDivisions {
            for requested in [false, true] {
                for window in stride(from: 600.0, through: 1_400, by: 0.5) {
                    let division = HouseWindowLayout.division(
                        window              : window,
                        isInspectorRequested: requested,
                        previous            : previous
                    )
                    let sidebar = HouseWindowLayout.sidebarWidth(for: division)
                    let inspector = division.isInspectorShown
                        ? HouseWindowLayout.inspectorWidth.ideal : 0
                    #expect(window - sidebar.ideal - inspector >= 460)
                    #expect(sidebar.minimum <= sidebar.ideal && sidebar.ideal <= sidebar.maximum)
                    if !requested { #expect(!division.isInspectorShown) }
                }
            }
        }
    }

    @Test("Narrowing compacts and closes at the ideal-width budgets")
    func narrowingUsesIdealWidths() {
        let cases: [(Double, Bool, Division?, Division)] = [
            (1_180, true, nil, Self.full),
            (1_100, true, nil, Self.full),
            (1_099, true, Self.full, Self.compact),
            (960, true, Self.compact, Self.compact),
            (959, true, Self.compact, .withoutInspector),
            (740, false, nil, .withoutInspector),
            (739, false, .withoutInspector, Self.narrow),
            (600, true, Self.full, Self.narrow)
        ]
        for (window, requested, previous, expected) in cases {
            #expect(HouseWindowLayout.division(
                window              : window,
                isInspectorRequested: requested,
                previous            : previous
            ) == expected)
        }
    }

    @Test("Columns return during widening only after the hysteresis margin")
    func wideningRestoresRequestedColumns() {
        let cases: [(Double, Bool, Division, Division)] = [
            (763, false, Self.narrow, Self.narrow),
            (764, false, Self.narrow, .withoutInspector),
            (983, true, .withoutInspector, .withoutInspector),
            (984, true, .withoutInspector, Self.compact),
            (1_123, true, Self.compact, Self.compact),
            (1_124, true, Self.compact, Self.full),
            (1_400, false, Self.narrow, .withoutInspector)
        ]
        for (window, requested, previous, expected) in cases {
            #expect(HouseWindowLayout.division(
                window              : window,
                isInspectorRequested: requested,
                previous            : previous
            ) == expected)
        }
    }

    @Test("Jitter near a compaction line changes the division once in each direction")
    func resizingAcrossALineDoesNotOscillate() {
        var previous = Self.full
        var changes = 0
        for window in [1_110.0, 1_099, 1_101, 1_098, 1_123, 1_124, 1_101] {
            let next = HouseWindowLayout.division(
                window              : window,
                isInspectorRequested: true,
                previous            : previous
            )
            if next != previous { changes += 1 }
            previous = next
        }
        #expect(changes == 2)
        #expect(previous == Self.full)
    }
}
