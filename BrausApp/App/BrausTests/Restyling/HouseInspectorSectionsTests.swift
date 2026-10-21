//
//  HouseInspectorSectionsTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import SwiftUI
import Testing
@testable import Braus

@Suite("HouseInspectorSections")
@MainActor
struct HouseInspectorSectionsTests {

    @Test("Screen is the inspector's first section when it shows, and the order holds otherwise")
    func order() {
        #expect(HouseInspector.parts(
            showsScreen: true,
            isBusy     : true
        ) == [.screen, .worker, .now, .model, .web, .turn])
        #expect(HouseInspector.parts(
            showsScreen: true,
            isBusy     : false
        ) == [.worker, .now, .model, .web, .turn])
        #expect(HouseInspector.parts(
            showsScreen: false,
            isBusy     : true
        ) == [.worker, .now, .model, .web, .turn])
    }

    @Test("The sections stand in a grouped form, and none of them can be collapsed")
    func noSectionCollapses() throws {
        #expect(String(reflecting: HouseInspector.Body.self).contains("Form<"))

        // A collapsible section holds a binding to its expansion; none of these do.
        let worker = try #require(MockHouse.sample.workers.first)
        let team   = MockTeam()
        let sections: [Any] = [
            HouseScreenSection(worker: worker),
            HouseNowSection(
                worker: worker,
                team  : team
            ),
            HouseModelSection(
                worker    : worker,
                team      : team,
                isChoosing: .constant(false)
            ),
            HouseWebSection(
                worker: worker,
                team  : team
            ),
            InspectorTurnSection(
                workerName: worker.name,
                turn      : .nothingYet
            ),
        ]
        for section in sections {
            let labels = Mirror(reflecting: section).children.compactMap(\.label)
            #expect(!labels.contains { $0.lowercased().contains("expanded") })
        }
    }
}
