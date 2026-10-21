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

    @Test("A row's subtitle says what the worker is doing or needs, else its role, never a status word in any state")
    func subtitles() {
        let workers = MockHouse.sample.workers
        let byName  = Dictionary(uniqueKeysWithValues: workers.map { ($0.name, $0.subtitle) })
        #expect(byName["Delivery"] == "Exports the stems")
        #expect(byName["Export"] == "Needs your OK to send")
        #expect(byName["Mastering"] == "Mixes and masters")
        #expect(byName["PT Agent"] == "Edits in Pro Tools")
        // Every worker in every state, as forced captures show them.
        for worker in workers {
            for status in WorkerStatus.allCases {
                var shown = worker
                shown.status = status
                switch status {
                case .busy, .waiting: #expect(shown.subtitle == worker.activity, "\(worker.name)")
                case .free, .off    : #expect(shown.subtitle == worker.role, "\(worker.name)")
                }
                let words = Set(shown.subtitle.lowercased().split(separator: " ").map(String.init))
                #expect(words.isDisjoint(with: ["busy", "idle", "free", "off", "waiting"]), "\(worker.name) \(status)")
                #expect(!shown.subtitle.contains { $0.isNumber }, "\(worker.name) \(status)")
            }
        }
    }

    @Test("Every shape has a worker, and no room touches its own shape or a look-alike")
    func shapes() {
        let workers = MockHouse.sample.workers
        let shapes  = workers.map(\.shape)
        #expect(Set(shapes) == Set(WorkerShape.allCases))
        // Rows and one column: the next room. Two columns under the wide first room: the room beside,
        // the one below, and diagonally the one below the other side.
        var touching = shapes.indices.dropFirst().map { ($0 - 1, $0) }
        touching += shapes.indices.dropFirst(2).map { ($0 - 2, $0) }
        touching += stride(from: 1, to: shapes.count - 3, by: 2).map { ($0, $0 + 3) }
        let alike: [Set<WorkerShape>] = [[.circle, .pentagon, .hexagon], [.square, .diamond], [.capsule, .lens]]
        for (first, second) in touching {
            let pair = Set([shapes[first], shapes[second]])
            #expect(pair.count == 2 && !alike.contains { pair.isSubset(of: $0) }, "\(first) and \(second)")
        }
        #expect(Set(workers.map(\.id)).count == workers.count)
    }
}
