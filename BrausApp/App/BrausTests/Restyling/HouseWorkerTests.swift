//
//  HouseWorkerTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import Testing
@testable import Braus

@Suite("HouseWorker")
struct HouseWorkerTests {

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

    @Test("A row's subtitle says what the worker is doing or needs, else its role, never a status word in any state")
    func subtitles() {
        let workers = HouseFixture.workers
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
}
