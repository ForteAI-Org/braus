//
//  MockHouseTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import Testing
@testable import Braus

@Suite("MockHouse")
struct MockHouseTests {

    @Test("Status light matches the design")
    func statusLight() throws {
        let busy = try #require(WorkerStatus.busy.light)
        #expect(busy.red == 255.0 / 255 && busy.green == 176.0 / 255 && busy.blue == 72.0 / 255)
        let free = try #require(WorkerStatus.free.light)
        #expect(free.red == 48.0 / 255 && free.green == 209.0 / 255 && free.blue == 88.0 / 255)
        let waiting = try #require(WorkerStatus.waiting.light)
        #expect(waiting.red == 120.0 / 255 && waiting.green == 170.0 / 255 && waiting.blue == 1)
        #expect(WorkerStatus.off.light == nil)
        #expect(WorkerStatus.busy.lightStrength == 1 && WorkerStatus.free.lightStrength == 0.5)
        #expect(WorkerStatus.waiting.lightStrength == 0.9 && WorkerStatus.off.lightStrength == 0)
    }

    @Test("The sample house")
    func sampleHouse() {
        let house = MockHouse.sample
        #expect(house.workers.map(\.name) == [
            "Delivery", "Render", "Mastering", "Ingest", "Mixing",
            "Design", "Export", "Research", "PT Agent",
        ])
        #expect(house.workers.map(\.status) == [
            .busy, .busy, .free, .waiting, .free,
            .free, .waiting, .free, .off,
        ])
        let byName = Dictionary(uniqueKeysWithValues: house.workers.map { ($0.name, $0) })
        #expect(byName["Delivery"]?.category == .audio)
        #expect(byName["Render"]?.category == .video)
        #expect(byName["Render"]?.badge == .attention)
        #expect(byName["Mastering"]?.category == .audio)
        #expect(byName["Ingest"]?.category == .files)
        #expect(byName["Ingest"]?.badge == .unread(2))
        #expect(byName["Mixing"]?.category == .audio)
        #expect(byName["Design"]?.category == .design)
        #expect(byName["Export"]?.category == .design)
        #expect(byName["Research"]?.category == .web)
        #expect(house.workers.filter { $0.badge != nil }.count == 2)
        #expect(house.archivedCount == 3)
        #expect(house.mostUsed == ["Delivery", "Ingest", "Research", "Render"])
    }

    @Test("Every sample worker has its own tint")
    func distinctTints() {
        let workers = MockHouse.sample.workers
        #expect(Set(workers.map { MascotDrawing($0.appearance) }).count == workers.count)
        #expect(Set(workers.map(\.id)).count == workers.count)
    }
}
